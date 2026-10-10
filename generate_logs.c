// Fast Log Generator - C version for billions of entries
// Compile: clang -O3 -o genlog generate_logs.c
// Usage: ./genlog <count> [output_file] [--start DATE --end DATE]

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <inttypes.h>
#include <string.h>
#include <errno.h>
#include <signal.h>
#include <time.h>

// Fast PRNG (xorshift64) - much faster than rand()
static uint64_t rng_state;

static inline uint64_t xorshift64(void) {
    uint64_t x = rng_state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    rng_state = x;
    return x;
}

static inline uint32_t fast_rand(uint32_t max) {
    return (uint32_t)(xorshift64() % max);
}

// Pre-computed level strings for fast lookup
static const char* LEVEL_NAMES[] = {"DEBUG", "INFO", "WARN", "ERROR"};

// Message templates
static const char* MESSAGES[] = {
    "Database connection established",
    "User login successful",
    "Request processed in 42ms",
    "Cache miss for key user_123",
    "Memory usage at 75%",
    "API rate limit exceeded",
    "File not found: config.yaml",
    "Connection timeout after 30s",
    "Invalid input received",
    "Server started on port 8080",
    "Scheduled task completed",
    "Authentication failed",
    "Disk space low warning",
    "New session created",
    "Background job finished"
};

static const char* INVALID_MSGS[] = {
    "this is not a valid log",
    "random garbage 12345",
    "missing timestamp",
    ""
};

#define NUM_MESSAGES 15
#define NUM_INVALID 4
#define WRITE_BUFFER_SIZE (4 * 1024 * 1024)  // 4MB buffer for max throughput
#define MAX_COUNT (UINT64_MAX / 100)         // Keeps the progress math (i * 100) from overflowing

// Date range for log generation (unix timestamps)
static int64_t start_timestamp = 0;
static int64_t end_timestamp = 0;
static int64_t timestamp_range = 0;

// Parse date string to unix timestamp (exactly YYYY-MM-DD or YYYY-MM-DD HH:MM:SS, UTC)
// Returns 0 on success, -1 if the string is malformed or not a real calendar date
static int parse_datetime(const char* str, int64_t* out) {
    static const char pattern[] = "dddd-dd-dd dd:dd:dd";
    static const int month_days[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    size_t n = strlen(str);
    if (n != 10 && n != 19) return -1;
    for (size_t i = 0; i < n; i++) {
        if (pattern[i] == 'd') {
            if (str[i] < '0' || str[i] > '9') return -1;
        } else if (str[i] != pattern[i]) {
            return -1;
        }
    }

    int year = (str[0]-'0')*1000 + (str[1]-'0')*100 + (str[2]-'0')*10 + (str[3]-'0');
    int month = (str[5]-'0')*10 + (str[6]-'0');
    int day = (str[8]-'0')*10 + (str[9]-'0');
    int hour = 0, min = 0, sec = 0;
    if (n == 19) {
        hour = (str[11]-'0')*10 + (str[12]-'0');
        min = (str[14]-'0')*10 + (str[15]-'0');
        sec = (str[17]-'0')*10 + (str[18]-'0');
    }

    if (month < 1 || month > 12) return -1;
    int leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
    int days_in_month = month_days[month - 1] + (month == 2 && leap);
    if (day < 1 || day > days_in_month) return -1;
    if (hour > 23 || min > 59 || sec > 59) return -1;

    // Days from civil (algorithm from Howard Hinnant)
    int y = year, m = month;
    if (m <= 2) { y -= 1; m += 12; }
    int64_t era = (y >= 0 ? y : y - 399) / 400;
    int64_t yoe = y - era * 400;
    int64_t doy = (153 * (m - 3) + 2) / 5 + day - 1;
    int64_t doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    int64_t days = era * 146097 + doe - 719468;
    *out = days * 86400 + hour * 3600 + min * 60 + sec;
    return 0;
}

// Parse "<digits>[K|M|B]" into an entry count
// Returns 0 on success, -1 on anything else (sign, garbage, unknown suffix, overflow)
static int parse_count(const char* str, uint64_t* out) {
    // strtoull would accept leading whitespace and a sign, so insist on a digit
    if (str[0] < '0' || str[0] > '9') return -1;
    char* endptr;
    errno = 0;
    unsigned long long value = strtoull(str, &endptr, 10);
    if (errno == ERANGE) return -1;

    uint64_t scale = 1;
    if (*endptr == 'K' || *endptr == 'k') scale = 1000ULL;
    else if (*endptr == 'M' || *endptr == 'm') scale = 1000000ULL;
    else if (*endptr == 'B' || *endptr == 'b') scale = 1000000000ULL;
    if (scale != 1) endptr++;
    if (*endptr != '\0') return -1;

    if (value > MAX_COUNT / scale) return -1;
    *out = (uint64_t)value * scale;
    return 0;
}

// Convert timestamp to date components
static void timestamp_to_date(int64_t ts, int* year, int* month, int* day, 
                              int* hour, int* min, int* sec) {
    int64_t days = ts / 86400;
    int64_t secs = ts % 86400;
    if (secs < 0) { secs += 86400; days--; }
    
    *hour = (int)(secs / 3600);
    *min = (int)((secs % 3600) / 60);
    *sec = (int)(secs % 60);
    
    // Civil from days (algorithm from Howard Hinnant)
    days += 719468;
    int64_t era = (days >= 0 ? days : days - 146096) / 146097;
    int64_t doe = days - era * 146097;
    int64_t yoe = (doe - doe/1460 + doe/36524 - doe/146096) / 365;
    int64_t y = yoe + era * 400;
    int64_t doy = doe - (365*yoe + yoe/4 - yoe/100);
    int64_t mp = (5*doy + 2) / 153;
    *day = (int)(doy - (153*mp + 2)/5 + 1);
    *month = (int)(mp + (mp < 10 ? 3 : -9));
    *year = (int)(y + (*month <= 2 ? 1 : 0));
}

// Fast integer to string (much faster than sprintf for numbers)
static inline int fast_itoa2(char* buf, int val) {
    buf[0] = '0' + (val / 10);
    buf[1] = '0' + (val % 10);
    return 2;
}

static inline int fast_itoa4(char* buf, int val) {
    buf[0] = '0' + (val / 1000);
    buf[1] = '0' + ((val / 100) % 10);
    buf[2] = '0' + ((val / 10) % 10);
    buf[3] = '0' + (val % 10);
    return 4;
}

// Generate a valid log line directly into buffer (no sprintf overhead)
static inline int generate_valid_entry(char* buf) {
    char* p = buf;
    
    const char* level = LEVEL_NAMES[fast_rand(4)];
    const char* msg = MESSAGES[fast_rand(NUM_MESSAGES)];
    
    // Generate timestamp within range
    int year, month, day, hour, min, sec;
    if (timestamp_range > 0) {
        int64_t ts = start_timestamp + (int64_t)(xorshift64() % (uint64_t)timestamp_range);
        timestamp_to_date(ts, &year, &month, &day, &hour, &min, &sec);
    } else {
        // Default: random dates in 2024-2025
        year = 2024 + fast_rand(2);
        month = 1 + fast_rand(12);
        day = 1 + fast_rand(28);
        hour = fast_rand(24);
        min = fast_rand(60);
        sec = fast_rand(60);
    }
    
    // Date
    p += fast_itoa4(p, year); *p++ = '-';
    p += fast_itoa2(p, month); *p++ = '-';
    p += fast_itoa2(p, day); *p++ = ' ';
    
    // Time
    p += fast_itoa2(p, hour); *p++ = ':';
    p += fast_itoa2(p, min); *p++ = ':';
    p += fast_itoa2(p, sec); *p++ = ' ';
    
    // Level
    while (*level) *p++ = *level++;
    *p++ = ' ';
    
    // Message
    while (*msg) *p++ = *msg++;
    *p++ = '\n';
    
    return (int)(p - buf);
}

// Generate invalid entry
static inline int generate_invalid_entry(char* buf) {
    const char* invalid = INVALID_MSGS[fast_rand(NUM_INVALID)];
    char* p = buf;
    while (*invalid) *p++ = *invalid++;
    *p++ = '\n';
    
    return (int)(p - buf);
}

static void print_usage(const char* prog) {
    fprintf(stderr, "Usage: %s <count> [output_file] [--start DATE --end DATE]\n", prog);
    fprintf(stderr, "  count       - Number of log entries (supports K, M, B suffixes)\n");
    fprintf(stderr, "  output_file - Output file (default: stdout)\n");
    fprintf(stderr, "  --start     - Start date (YYYY-MM-DD or YYYY-MM-DD HH:MM:SS), needs --end\n");
    fprintf(stderr, "  --end       - End date (exclusive, must be later than --start)\n");
    fprintf(stderr, "  -h, --help  - Show this help\n");
    fprintf(stderr, "\nExamples:\n");
    fprintf(stderr, "  %s 1M > logs.txt                              # 1 million entries\n", prog);
    fprintf(stderr, "  %s 1M logs.txt --start 2024-01-01 --end 2024-02-01  # January 2024\n", prog);
    fprintf(stderr, "  %s 1B logs.txt                                # 1 billion entries\n", prog);
}

int main(int argc, char** argv) {
    const char* prog = argc > 0 ? argv[0] : "genlog";
    if (argc < 2) {
        print_usage(prog);
        return 1;
    }
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            print_usage(prog);
            return 0;
        }
    }

    // Parse count with K/M/B suffix
    uint64_t count;
    if (parse_count(argv[1], &count) != 0) {
        fprintf(stderr, "Error: invalid count '%s' (expected digits with an optional K, M or B suffix)\n", argv[1]);
        return 1;
    }

    // Parse remaining arguments
    const char* output_file = NULL;
    int has_start = 0, has_end = 0;
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--start") == 0 || strcmp(argv[i], "--end") == 0) {
            const char* opt = argv[i];
            int is_start = (opt[2] == 's');
            if (i + 1 >= argc) {
                fprintf(stderr, "Error: option %s requires a value\n", opt);
                return 1;
            }
            if (parse_datetime(argv[++i], is_start ? &start_timestamp : &end_timestamp) != 0) {
                fprintf(stderr, "Error: invalid date '%s' for %s (expected YYYY-MM-DD or YYYY-MM-DD HH:MM:SS)\n",
                        argv[i], opt);
                return 1;
            }
            if (is_start) has_start = 1; else has_end = 1;
        } else if (argv[i][0] == '-') {
            fprintf(stderr, "Error: unknown option '%s'\n", argv[i]);
            return 1;
        } else if (output_file) {
            fprintf(stderr, "Error: unexpected argument '%s' (output file is already '%s')\n",
                    argv[i], output_file);
            return 1;
        } else {
            output_file = argv[i];
        }
    }
    
    // Calculate timestamp range
    if (has_start != has_end) {
        fprintf(stderr, "Error: --start and --end must be given together\n");
        return 1;
    }
    if (has_start) {
        if (end_timestamp <= start_timestamp) {
            fprintf(stderr, "Error: --end must be later than --start\n");
            return 1;
        }
        timestamp_range = end_timestamp - start_timestamp;
    }

    // Allocate buffers
    char* write_buffer = malloc(WRITE_BUFFER_SIZE);
    if (!write_buffer) {
        fprintf(stderr, "Error: out of memory\n");
        return 1;
    }
    char line_buffer[512];

    // Open output
    FILE* out = stdout;
    if (output_file) {
        out = fopen(output_file, "w");
        if (!out) {
            fprintf(stderr, "Error: cannot open output file '%s': %s\n", output_file, strerror(errno));
            free(write_buffer);
            return 1;
        }
    }
    setvbuf(out, write_buffer, _IOFBF, WRITE_BUFFER_SIZE);

#ifdef SIGXFSZ
    // Hitting a file size limit should surface as a write error, not kill the process.
    // SIGPIPE keeps its default: a reader that goes away ends the run quietly.
    signal(SIGXFSZ, SIG_IGN);
#endif

    // Seed RNG with high-resolution time
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    rng_state = (uint64_t)ts.tv_sec ^ (uint64_t)ts.tv_nsec ^ 0xDEADBEEFCAFEULL;
    if (rng_state == 0) rng_state = 1;

    uint64_t valid_count = 0, invalid_count = 0;
    uint64_t progress_interval = count / 100;
    if (progress_interval == 0) progress_interval = 1;
    int progress_shown = 0;
    int write_errno = 0;

    fprintf(stderr, "Generating %" PRIu64 " log entries...\n", count);
    
    struct timespec start_ts;
    clock_gettime(CLOCK_MONOTONIC, &start_ts);

    for (uint64_t i = 0; i < count; i++) {
        // Progress every 1%
        if (i % progress_interval == 0 && i > 0) {
            fprintf(stderr, "\r%" PRIu64 "%% (%" PRIu64 "/%" PRIu64 ")", (i * 100) / count, i, count);
            progress_shown = 1;
        }

        int len;
        // 90% valid, 10% invalid
        if (fast_rand(10) < 9) {
            len = generate_valid_entry(line_buffer);
            valid_count++;
        } else {
            len = generate_invalid_entry(line_buffer);
            invalid_count++;
        }
        
        // Stop at the first failed write (full disk, closed pipe with SIGPIPE
        // ignored) instead of spinning through the remaining entries
        if (fwrite(line_buffer, 1, (size_t)len, out) != (size_t)len) {
            write_errno = errno ? errno : EIO;
            break;
        }
    }

    // The stream keeps using write_buffer until it is closed (stdout included),
    // so close first and free afterwards. fclose also reports a failed final flush.
    if (fclose(out) != 0 && !write_errno) write_errno = errno ? errno : EIO;
    free(write_buffer);

    if (write_errno) {
        if (progress_shown) fputc('\n', stderr);
        fprintf(stderr, "Error: write to %s failed: %s\n",
                output_file ? output_file : "stdout", strerror(write_errno));
        return 1;
    }

    struct timespec end_ts;
    clock_gettime(CLOCK_MONOTONIC, &end_ts);
    double elapsed = (end_ts.tv_sec - start_ts.tv_sec) + 
                     (end_ts.tv_nsec - start_ts.tv_nsec) / 1e9;
    if (elapsed < 0.001) elapsed = 0.001;

    fprintf(stderr, "\r100%% Complete!                    \n");
    fprintf(stderr, "Generated: %" PRIu64 " entries (%" PRIu64 " valid, %" PRIu64 " invalid)\n",
            count, valid_count, invalid_count);
    fprintf(stderr, "Time: %.2f seconds (~%.0f entries/sec)\n", 
            elapsed, (double)count / elapsed);

    return 0;
}
