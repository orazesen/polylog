// Fast Log Generator - C version for billions of entries
// Uses LogEntry struct for consistency with log processor
// Compile: clang -O3 -o genlog generate_logs.c
// Usage: ./genlog <count> [output_file]

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include "logentry.h"

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

// Date range for log generation (unix timestamps)
static int64_t start_timestamp = 0;
static int64_t end_timestamp = 0;
static int64_t timestamp_range = 0;

// Parse date string to unix timestamp (YYYY-MM-DD or YYYY-MM-DD HH:MM:SS)
static int64_t parse_datetime(const char* str) {
    int year = 0, month = 1, day = 1, hour = 0, min = 0, sec = 0;
    // Parse YYYY-MM-DD
    if (strlen(str) >= 10) {
        year = (str[0]-'0')*1000 + (str[1]-'0')*100 + (str[2]-'0')*10 + (str[3]-'0');
        month = (str[5]-'0')*10 + (str[6]-'0');
        day = (str[8]-'0')*10 + (str[9]-'0');
    }
    // Parse optional HH:MM:SS
    if (strlen(str) >= 19) {
        hour = (str[11]-'0')*10 + (str[12]-'0');
        min = (str[14]-'0')*10 + (str[15]-'0');
        sec = (str[17]-'0')*10 + (str[18]-'0');
    }
    // Convert to timestamp (simplified, assumes UTC)
    int y = year, m = month;
    if (m <= 2) { y -= 1; m += 12; }
    int64_t era = y / 400;
    int64_t yoe = y - era * 400;
    int64_t doy = (153 * (m - 3) + 2) / 5 + day - 1;
    int64_t doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    int64_t days = era * 146097 + doe - 719468;
    return days * 86400 + hour * 3600 + min * 60 + sec;
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
static inline int generate_valid_entry(char* buf, struct LogEntry* entry) {
    char* p = buf;
    
    // Populate LogEntry
    entry->level = fast_rand(4);  // LOG_DEBUG to LOG_ERROR
    entry->valid = 1;
    int msg_idx = fast_rand(NUM_MESSAGES);
    const char* msg = MESSAGES[msg_idx];
    entry->msg_len = strlen(msg);
    
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
    const char* level = LEVEL_NAMES[entry->level];
    while (*level) *p++ = *level++;
    *p++ = ' ';
    
    // Message (also copy to entry)
    const char* m = msg;
    char* dst = entry->msg;
    while (*m) {
        *p++ = *m;
        *dst++ = *m++;
    }
    *dst = '\0';
    *p++ = '\n';
    
    return (int)(p - buf);
}

// Generate invalid entry
static inline int generate_invalid_entry(char* buf, struct LogEntry* entry) {
    entry->valid = 0;
    entry->level = 0;
    entry->msg_len = 0;
    entry->msg[0] = '\0';
    
    const char* invalid = INVALID_MSGS[fast_rand(NUM_INVALID)];
    char* p = buf;
    while (*invalid) *p++ = *invalid++;
    *p++ = '\n';
    
    return (int)(p - buf);
}

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <count> [output_file] [--start DATE] [--end DATE]\n", argv[0]);
        fprintf(stderr, "  count       - Number of log entries (supports K, M, B suffixes)\n");
        fprintf(stderr, "  output_file - Output file (default: stdout)\n");
        fprintf(stderr, "  --start     - Start date (YYYY-MM-DD or YYYY-MM-DD HH:MM:SS)\n");
        fprintf(stderr, "  --end       - End date\n");
        fprintf(stderr, "\nExamples:\n");
        fprintf(stderr, "  %s 1M > logs.txt                              # 1 million entries\n", argv[0]);
        fprintf(stderr, "  %s 1M logs.txt --start 2024-01-01 --end 2024-01-31  # January 2024\n", argv[0]);
        fprintf(stderr, "  %s 1B logs.txt                                # 1 billion entries\n", argv[0]);
        return 1;
    }

    // Parse count with K/M/B suffix
    char* endptr;
    uint64_t count = strtoull(argv[1], &endptr, 10);
    if (*endptr == 'K' || *endptr == 'k') count *= 1000ULL;
    else if (*endptr == 'M' || *endptr == 'm') count *= 1000000ULL;
    else if (*endptr == 'B' || *endptr == 'b') count *= 1000000000ULL;

    // Parse remaining arguments
    const char* output_file = NULL;
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--start") == 0 && i + 1 < argc) {
            start_timestamp = parse_datetime(argv[++i]);
        } else if (strcmp(argv[i], "--end") == 0 && i + 1 < argc) {
            end_timestamp = parse_datetime(argv[++i]);
        } else if (argv[i][0] != '-') {
            output_file = argv[i];
        }
    }
    
    // Calculate timestamp range
    if (start_timestamp > 0 && end_timestamp > start_timestamp) {
        timestamp_range = end_timestamp - start_timestamp;
    }

    // Open output
    FILE* out = stdout;
    if (output_file) {
        out = fopen(output_file, "w");
        if (!out) {
            perror("Failed to open output file");
            return 1;
        }
    }

    // Allocate buffers
    char* write_buffer = malloc(WRITE_BUFFER_SIZE);
    char* line_buffer = malloc(512);
    setvbuf(out, write_buffer, _IOFBF, WRITE_BUFFER_SIZE);

    // Seed RNG with high-resolution time
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    rng_state = (uint64_t)ts.tv_sec ^ (uint64_t)ts.tv_nsec ^ 0xDEADBEEFCAFEULL;
    if (rng_state == 0) rng_state = 1;

    struct LogEntry entry;
    uint64_t valid_count = 0, invalid_count = 0;
    uint64_t progress_interval = count / 100;
    if (progress_interval == 0) progress_interval = 1;

    fprintf(stderr, "Generating %llu log entries (using LogEntry struct)...\n", count);
    
    struct timespec start_ts;
    clock_gettime(CLOCK_MONOTONIC, &start_ts);

    for (uint64_t i = 0; i < count; i++) {
        // Progress every 1%
        if (i % progress_interval == 0 && i > 0) {
            fprintf(stderr, "\r%llu%% (%llu/%llu)", (i * 100) / count, i, count);
        }

        int len;
        // 90% valid, 10% invalid
        if (fast_rand(10) < 9) {
            len = generate_valid_entry(line_buffer, &entry);
            valid_count++;
        } else {
            len = generate_invalid_entry(line_buffer, &entry);
            invalid_count++;
        }
        
        fwrite(line_buffer, 1, len, out);
    }

    struct timespec end_ts;
    clock_gettime(CLOCK_MONOTONIC, &end_ts);
    double elapsed = (end_ts.tv_sec - start_ts.tv_sec) + 
                     (end_ts.tv_nsec - start_ts.tv_nsec) / 1e9;
    if (elapsed < 0.001) elapsed = 0.001;

    fprintf(stderr, "\r100%% Complete!                    \n");
    fprintf(stderr, "Generated: %llu entries (%llu valid, %llu invalid)\n", 
            count, valid_count, invalid_count);
    fprintf(stderr, "Time: %.2f seconds (~%.0f entries/sec)\n", 
            elapsed, count / elapsed);

    if (out != stdout) fclose(out);
    free(write_buffer);
    free(line_buffer);
    return 0;
}
