// C - Ultra-fast Log Reader with Multi-language Pipeline
// Uses large read() buffers + SIMD + pthreads
// Pipeline: C (reader) -> Zig (parser) -> Rust (processor) -> C++ (formatter)
#include <pthread.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <arm_neon.h>
#include "logentry.h"

// Config file path
#define MAX_CONFIG_PATH 512
static char config_path[MAX_CONFIG_PATH] = "";

// Get current time in seconds
static double get_time(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec / 1000000.0;
}

// External functions from other languages
extern void parse_log(const char* line, int len, struct LogEntry* entry);    // Zig
extern void process_log(struct LogEntry* entry);                              // Rust  
extern void set_filter(int level_mask, int active);                           // Rust
extern void set_time_filter(long long after, long long before, int active);   // Rust
extern void set_message_filter(const char* pattern, int len);                 // Rust
extern void format_output(struct LogEntry* entry);                            // C++
extern void set_output_format(int format);                                    // C++
extern void set_output_fd(int fd);                                            // C++
extern void set_level_fds(int fd_debug, int fd_info, int fd_warn, int fd_err); // C++
extern void flush_buffer(void);                                               // C++

// Parse date string to unix timestamp (YYYY-MM-DD or YYYY-MM-DD HH:MM:SS)
static long long parse_datetime(const char* str) {
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
    long long era = y / 400;
    long long yoe = y - era * 400;
    long long doy = (153 * (m - 3) + 2) / 5 + day - 1;
    long long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    long long days = era * 146097 + doe - 719468;
    return days * 86400 + hour * 3600 + min * 60 + sec;
}

#define MAX_THREADS 12
#define CHUNK_SIZE (64 * 1024 * 1024)  // 64MB chunks
#define MAX_TIME_BUCKETS 8760  // Max 1 year of hourly buckets

static int num_threads = 8;
static int count_only = 0;  // Skip output if set
static int stats_mode = 0;  // 0=off, 1=hourly, 2=daily, 3=minute, 4=by-level
static int split_by_level = 0;  // Write separate files per level

// Time bucket for aggregation
typedef struct {
    long long timestamp;  // Hour or day start
    unsigned long long levels[4];
    unsigned long long total;
} TimeBucket;

static TimeBucket time_buckets[MAX_TIME_BUCKETS];
static int num_buckets = 0;
static pthread_mutex_t bucket_lock = PTHREAD_MUTEX_INITIALIZER;

// Cache-line aligned stats
typedef struct __attribute__((aligned(64))) {
    unsigned long long count;
    unsigned long long valid;
    unsigned long long invalid;
    unsigned long long matched;  // Entries that passed all filters
    unsigned long long levels[4];
} Stats;

// Work item
typedef struct {
    char* buffer;
    size_t size;
    int has_partial_start;
    int has_partial_end;
    Stats stats;
} WorkItem;

// SIMD newline finder
static inline const char* find_newline(const char* p, const char* end) {
    uint8x16_t nl = vdupq_n_u8('\n');
    while (p + 16 <= end) {
        uint8x16_t v = vld1q_u8((const uint8_t*)p);
        uint8x16_t eq = vceqq_u8(v, nl);
        uint64_t m = vgetq_lane_u64(vreinterpretq_u64_u8(eq), 0);
        if (m) {
            for (int i = 0; i < 8; i++) if (p[i] == '\n') return p + i;
        }
        m = vgetq_lane_u64(vreinterpretq_u64_u8(eq), 1);
        if (m) {
            for (int i = 8; i < 16; i++) if (p[i] == '\n') return p + i;
        }
        p += 16;
    }
    while (p < end && *p != '\n') p++;
    return p;
}

// Record to time bucket (for stats mode)
static void record_bucket(long long timestamp, int level) {
    long long bucket_ts;
    if (stats_mode == 1) {
        bucket_ts = (timestamp / 3600) * 3600;  // Round to hour
    } else if (stats_mode == 2) {
        bucket_ts = (timestamp / 86400) * 86400;  // Round to day
    } else if (stats_mode == 3) {
        bucket_ts = (timestamp / 60) * 60;  // Round to minute
    } else {
        bucket_ts = level;  // Use level as bucket key for by-level mode
    }
    
    pthread_mutex_lock(&bucket_lock);
    // Find or create bucket
    int idx = -1;
    for (int i = 0; i < num_buckets; i++) {
        if (time_buckets[i].timestamp == bucket_ts) {
            idx = i;
            break;
        }
    }
    if (idx < 0 && num_buckets < MAX_TIME_BUCKETS) {
        idx = num_buckets++;
        time_buckets[idx].timestamp = bucket_ts;
        for (int i = 0; i < 4; i++) time_buckets[idx].levels[i] = 0;
        time_buckets[idx].total = 0;
    }
    if (idx >= 0) {
        if (level >= 0 && level <= 3) time_buckets[idx].levels[level]++;
        time_buckets[idx].total++;
    }
    pthread_mutex_unlock(&bucket_lock);
}

// Fast inline validation + level detection using multi-language pipeline
static inline void process_line(const char* line, int len, Stats* stats) {
    stats->count++;
    
    // Use Zig parser for validation
    struct LogEntry entry;
    parse_log(line, len, &entry);
    
    if (!entry.valid) {
        stats->invalid++;
        return;
    }
    
    // Use Rust processor for additional processing (filtering)
    process_log(&entry);
    
    stats->valid++;
    if (entry.level >= 0 && entry.level <= 3) {
        stats->levels[entry.level]++;
    }
    
    // Count entries that passed filters
    if (entry.filtered) {
        stats->matched++;
        
        // Record to time bucket if in stats mode
        if (stats_mode > 0) {
            record_bucket(entry.timestamp, entry.level);
        }
    }
    
    // Use C++ formatter for output (if not count-only mode and not stats mode)
    if (!count_only && stats_mode == 0) {
        format_output(&entry);
    }
}

// Process a buffer
static void process_buffer(const char* buf, size_t size, Stats* stats, int skip_first) {
    const char* p = buf;
    const char* end = buf + size;
    
    // Skip to first complete line if needed
    if (skip_first && p < end) {
        p = find_newline(p, end);
        if (p < end) p++;
    }
    
    while (p < end) {
        const char* nl = find_newline(p, end);
        int len = (int)(nl - p);
        if (len > 0) process_line(p, len, stats);
        else if (len == 0) { stats->count++; stats->invalid++; }
        p = nl + 1;
    }
}

// Thread pool for parallel processing
static pthread_mutex_t queue_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t queue_cond = PTHREAD_COND_INITIALIZER;
static WorkItem* work_queue[1024];
static int queue_head = 0, queue_tail = 0;
static int workers_done = 0;
static int all_submitted = 0;

static void* worker_thread(void* arg) {
    Stats* global_stats = (Stats*)arg;
    Stats local = {0};
    
    while (1) {
        pthread_mutex_lock(&queue_lock);
        while (queue_head == queue_tail && !all_submitted) {
            pthread_cond_wait(&queue_cond, &queue_lock);
        }
        if (queue_head == queue_tail && all_submitted) {
            pthread_mutex_unlock(&queue_lock);
            break;
        }
        WorkItem* item = work_queue[queue_head++ % 1024];
        pthread_mutex_unlock(&queue_lock);
        
        Stats chunk_stats = {0};
        process_buffer(item->buffer, item->size, &chunk_stats, item->has_partial_start);
        
        local.count += chunk_stats.count;
        local.valid += chunk_stats.valid;
        local.invalid += chunk_stats.invalid;
        for (int i = 0; i < 4; i++) local.levels[i] += chunk_stats.levels[i];
        
        free(item->buffer);
        free(item);
    }
    
    // Merge to global
    pthread_mutex_lock(&queue_lock);
    global_stats->count += local.count;
    global_stats->valid += local.valid;
    global_stats->invalid += local.invalid;
    for (int i = 0; i < 4; i++) global_stats->levels[i] += local.levels[i];
    pthread_mutex_unlock(&queue_lock);
    
    return NULL;
}

static void print_num(unsigned long long n) {
    char buf[24]; snprintf(buf, sizeof(buf), "%llu", n);
    write(2, buf, strlen(buf));
}
static void print_err(const char* s) { write(2, s, strlen(s)); }

// Parse level filter and configure Rust processor
// Returns bitmask: bit0=DEBUG, bit1=INFO, bit2=WARN, bit3=ERROR
static void configure_filter(const char* arg) {
    int mask = 0;
    const char* p = arg;
    
    while (*p) {
        while (*p == ',' || *p == ' ') p++;
        if (!*p) break;
        
        if (strncmp(p, "DEBUG", 5) == 0) { mask |= 1; p += 5; }
        else if (strncmp(p, "INFO", 4) == 0) { mask |= 2; p += 4; }
        else if (strncmp(p, "WARN", 4) == 0) { mask |= 4; p += 4; }
        else if (strncmp(p, "ERROR", 5) == 0) { mask |= 8; p += 5; }
        else p++;
    }
    
    // Call Rust to set filter
    set_filter(mask, 1);
}

#define MAX_FILES 256

int main(int argc, char** argv) {
    const char* filepaths[MAX_FILES];
    int num_files = 0;
    const char* output_path = NULL;
    long long time_after = 0;
    long long time_before = 0x7FFFFFFFFFFFFFFFLL;  // LLONG_MAX
    int time_filter_active = 0;
    int follow_mode = 0;  // -f flag for tail-like following
    
    for (int i = 1; i < argc; i++) {
        if ((strcmp(argv[i], "-t") == 0) && i + 1 < argc) {
            num_threads = atoi(argv[++i]);
            if (num_threads < 1) num_threads = 1;
            if (num_threads > MAX_THREADS) num_threads = MAX_THREADS;
        } else if ((strcmp(argv[i], "-l") == 0) && i + 1 < argc) {
            configure_filter(argv[++i]);
        } else if ((strcmp(argv[i], "-o") == 0) && i + 1 < argc) {
            const char* fmt = argv[++i];
            if (strcmp(fmt, "json") == 0) set_output_format(0);
            else if (strcmp(fmt, "csv") == 0) set_output_format(1);
            else if (strcmp(fmt, "tsv") == 0) set_output_format(2);
            else if (strcmp(fmt, "raw") == 0) set_output_format(3);
            else if (strcmp(fmt, "jsonl") == 0) set_output_format(4);  // JSON Lines
            else { print_err("Error: unknown format (use json,jsonl,csv,tsv,raw)\n"); return 1; }
        } else if ((strcmp(argv[i], "-O") == 0) && i + 1 < argc) {
            output_path = argv[++i];
        } else if ((strcmp(argv[i], "--after") == 0) && i + 1 < argc) {
            time_after = parse_datetime(argv[++i]);
            time_filter_active = 1;
        } else if ((strcmp(argv[i], "--before") == 0) && i + 1 < argc) {
            time_before = parse_datetime(argv[++i]);
            time_filter_active = 1;
        } else if ((strcmp(argv[i], "-m") == 0) && i + 1 < argc) {
            const char* pattern = argv[++i];
            set_message_filter(pattern, strlen(pattern));
        } else if (strcmp(argv[i], "-f") == 0 || strcmp(argv[i], "--follow") == 0) {
            follow_mode = 1;
        } else if (strcmp(argv[i], "--stats") == 0 && i + 1 < argc) {
            const char* mode = argv[++i];
            if (strcmp(mode, "hourly") == 0) stats_mode = 1;
            else if (strcmp(mode, "daily") == 0) stats_mode = 2;
            else if (strcmp(mode, "minute") == 0) stats_mode = 3;
            else if (strcmp(mode, "by-level") == 0) stats_mode = 4;
            else { print_err("Error: unknown stats mode (use hourly,daily,minute,by-level)\n"); return 1; }
        } else if (strcmp(argv[i], "--split-by-level") == 0) {
            split_by_level = 1;
        } else if (strcmp(argv[i], "--count-only") == 0) {
            count_only = 1;
        } else if (strcmp(argv[i], "--config") == 0 && i + 1 < argc) {
            strncpy(config_path, argv[++i], MAX_CONFIG_PATH - 1);
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            print_err("Usage: logproc [OPTIONS] <files...>\n\n");
            print_err("Options:\n");
            print_err("  -t N             Use N threads (default: 8, max: 12)\n");
            print_err("  -l LEVELS        Filter by level: DEBUG,INFO,WARN,ERROR\n");
            print_err("  -o FORMAT        Output format: json, jsonl, csv, tsv, raw\n");
            print_err("  -O FILE          Write output to FILE instead of stdout\n");
            print_err("  -m PATTERN       Filter messages containing PATTERN\n");
            print_err("  -f, --follow     Follow file for new lines (like tail -f)\n");
            print_err("  --stats MODE     Aggregate: hourly, daily, minute, by-level\n");
            print_err("  --after DATE     Only logs after DATE (YYYY-MM-DD [HH:MM:SS])\n");
            print_err("  --before DATE    Only logs before DATE\n");
            print_err("  --split-by-level Write separate files: debug.txt, info.txt, etc.\n");
            print_err("  --config FILE    Load config from FILE\n");
            print_err("  --count-only     Skip output, only count\n");
            print_err("\nExamples:\n");
            print_err("  logproc -l ERROR file.txt                  # Only ERROR logs\n");
            print_err("  logproc --stats hourly file.txt            # Hourly breakdown\n");
            print_err("  logproc --split-by-level file.txt          # Separate files\n");
            print_err("  logproc -o jsonl file.txt                  # Streaming JSON Lines\n");
            print_err("  cat file.txt | logproc                     # Read from stdin\n");
            return 0;
        } else {
            // Collect input files
            if (num_files < MAX_FILES) {
                filepaths[num_files++] = argv[i];
            }
        }
    }
    
    // Configure time filter in Rust
    if (time_filter_active) {
        set_time_filter(time_after, time_before, 1);
    }
    
    // Load config file if specified
    if (config_path[0]) {
        FILE* cfg = fopen(config_path, "r");
        if (cfg) {
            char line[512];
            while (fgets(line, sizeof(line), cfg)) {
                // Remove newline
                char* nl = strchr(line, '\n');
                if (nl) *nl = 0;
                // Skip empty lines and comments
                if (!line[0] || line[0] == '#') continue;
                // Parse key=value
                char* eq = strchr(line, '=');
                if (!eq) continue;
                *eq = 0;
                char* key = line;
                char* val = eq + 1;
                // Apply config
                if (strcmp(key, "levels") == 0) configure_filter(val);
                else if (strcmp(key, "format") == 0) {
                    if (strcmp(val, "json") == 0) set_output_format(0);
                    else if (strcmp(val, "csv") == 0) set_output_format(1);
                    else if (strcmp(val, "tsv") == 0) set_output_format(2);
                    else if (strcmp(val, "raw") == 0) set_output_format(3);
                    else if (strcmp(val, "jsonl") == 0) set_output_format(4);
                }
                else if (strcmp(key, "pattern") == 0) set_message_filter(val, strlen(val));
                else if (strcmp(key, "stats") == 0) {
                    if (strcmp(val, "hourly") == 0) stats_mode = 1;
                    else if (strcmp(val, "daily") == 0) stats_mode = 2;
                    else if (strcmp(val, "minute") == 0) stats_mode = 3;
                    else if (strcmp(val, "by-level") == 0) stats_mode = 4;
                }
                else if (strcmp(key, "after") == 0) { time_after = parse_datetime(val); set_time_filter(time_after, time_before, 1); }
                else if (strcmp(key, "before") == 0) { time_before = parse_datetime(val); set_time_filter(time_after, time_before, 1); }
                else if (strcmp(key, "threads") == 0) { num_threads = atoi(val); if (num_threads < 1) num_threads = 1; if (num_threads > MAX_THREADS) num_threads = MAX_THREADS; }
            }
            fclose(cfg);
            print_err("Loaded config: "); print_err(config_path); print_err("\n");
        } else {
            print_err("Warning: cannot open config file: "); print_err(config_path); print_err("\n");
        }
    }
    
    // Open output file if specified
    int output_fd = -1;
    if (output_path) {
        output_fd = open(output_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (output_fd < 0) { print_err("Error: cannot open output file\n"); return 1; }
        set_output_fd(output_fd);
    }
    
    // Open split-by-level output files
    int level_fds[4] = {-1, -1, -1, -1};
    if (split_by_level) {
        const char* level_files[] = {"debug.txt", "info.txt", "warn.txt", "error.txt"};
        for (int i = 0; i < 4; i++) {
            level_fds[i] = open(level_files[i], O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (level_fds[i] < 0) { print_err("Error: cannot open "); print_err(level_files[i]); print_err("\n"); return 1; }
        }
        set_level_fds(level_fds[0], level_fds[1], level_fds[2], level_fds[3]);
    }
    
    double start_time = get_time();
    Stats global_stats = {0};
    size_t total_read = 0;
    
    // Start worker threads
    pthread_t threads[MAX_THREADS];
    for (int i = 0; i < num_threads; i++) {
        pthread_create(&threads[i], NULL, worker_thread, &global_stats);
    }
    
    // Process each file (or stdin if no files)
    int file_count = (num_files == 0) ? 1 : num_files;
    for (int file_idx = 0; file_idx < file_count; file_idx++) {
        const char* filepath = (num_files == 0) ? NULL : filepaths[file_idx];
        int fd;
        int from_stdin = 0;
        size_t file_size = 0;
        
        if (!filepath || strcmp(filepath, "-") == 0) {
            fd = 0;  // stdin
            from_stdin = 1;
            if (file_idx == 0) {
                print_err("Reading from stdin with ");
                print_num(num_threads); print_err(" threads...\n");
            }
        } else {
            fd = open(filepath, O_RDONLY);
            if (fd < 0) {
                print_err("Warning: cannot open "); print_err(filepath); print_err("\n");
                continue;
            }
            struct stat st;
            fstat(fd, &st);
            file_size = st.st_size;
            
            if (num_files > 1) {
                print_err("["); print_num(file_idx + 1); print_err("/"); print_num(num_files); print_err("] ");
            }
            print_err("Processing "); print_err(filepath); print_err(" (");
            print_num(file_size / (1024*1024)); print_err(" MB)...\n");
        }
        
        // Read file in chunks
        size_t file_read = 0;
        char* overlap = NULL;
        size_t overlap_len = 0;
        
        while (from_stdin || file_read < file_size) {
            size_t to_read = CHUNK_SIZE;
            if (!from_stdin && file_read + to_read > file_size) 
                to_read = file_size - file_read;
            
            char* buffer = malloc(to_read + overlap_len + 1);
            
            if (overlap_len > 0) {
                memcpy(buffer, overlap, overlap_len);
                free(overlap);
            }
            
            ssize_t n = read(fd, buffer + overlap_len, to_read);
            if (n <= 0) { free(buffer); break; }
            
            size_t buf_size = overlap_len + n;
            file_read += n;
            total_read += n;
            int more_data = from_stdin || (file_read < file_size);
            
            size_t last_nl = buf_size;
            while (last_nl > 0 && buffer[last_nl - 1] != '\n') last_nl--;
            
            if (last_nl == 0 && more_data) {
                overlap = buffer;
                overlap_len = buf_size;
                continue;
            }
            
            if (last_nl < buf_size && more_data) {
                overlap_len = buf_size - last_nl;
                overlap = malloc(overlap_len);
                memcpy(overlap, buffer + last_nl, overlap_len);
                buf_size = last_nl;
            } else {
                overlap = NULL;
                overlap_len = 0;
            }
            
            WorkItem* item = malloc(sizeof(WorkItem));
            item->buffer = buffer;
            item->size = buf_size;
            item->has_partial_start = 0;
            
            pthread_mutex_lock(&queue_lock);
            work_queue[queue_tail++ % 1024] = item;
            pthread_cond_signal(&queue_cond);
            pthread_mutex_unlock(&queue_lock);
        }
        
        // Handle final overlap for this file (only if not following)
        if (overlap_len > 0 && !follow_mode) {
            WorkItem* item = malloc(sizeof(WorkItem));
            item->buffer = overlap;
            item->size = overlap_len;
            item->has_partial_start = 0;
            
            pthread_mutex_lock(&queue_lock);
            work_queue[queue_tail++ % 1024] = item;
            pthread_cond_signal(&queue_cond);
            pthread_mutex_unlock(&queue_lock);
            overlap = NULL;
            overlap_len = 0;
        }
        
        // Follow mode: keep reading new lines
        if (follow_mode && !from_stdin && file_idx == file_count - 1) {
            // Signal workers to finish current batch first
            pthread_mutex_lock(&queue_lock);
            all_submitted = 1;
            pthread_cond_broadcast(&queue_cond);
            pthread_mutex_unlock(&queue_lock);
            for (int i = 0; i < num_threads; i++) pthread_join(threads[i], NULL);
            flush_buffer();
            
            print_err("Following "); print_err(filepath); print_err(" (Ctrl+C to stop)...\n");
            
            // Single-threaded follow loop
            char line_buf[4096];
            size_t line_len = overlap_len;
            if (overlap_len > 0) {
                memcpy(line_buf, overlap, overlap_len);
                free(overlap);
            }
            
            fd = open(filepath, O_RDONLY);
            lseek(fd, file_read, SEEK_SET);
            
            while (1) {
                ssize_t n = read(fd, line_buf + line_len, sizeof(line_buf) - line_len - 1);
                if (n > 0) {
                    line_len += n;
                    line_buf[line_len] = 0;
                    
                    // Process complete lines
                    char* start = line_buf;
                    char* nl;
                    while ((nl = strchr(start, '\n')) != NULL) {
                        *nl = 0;
                        int len = nl - start;
                        if (len > 0) {
                            Stats s = {0};
                            struct LogEntry entry;
                            parse_log(start, len, &entry);
                            if (entry.valid) {
                                process_log(&entry);
                                global_stats.valid++;
                                if (entry.level >= 0 && entry.level <= 3)
                                    global_stats.levels[entry.level]++;
                                if (!count_only && entry.filtered) {
                                    format_output(&entry);
                                    flush_buffer();
                                }
                            } else {
                                global_stats.invalid++;
                            }
                            global_stats.count++;
                        }
                        start = nl + 1;
                    }
                    
                    // Keep incomplete line
                    line_len = strlen(start);
                    if (line_len > 0) memmove(line_buf, start, line_len);
                } else {
                    usleep(100000);  // 100ms poll interval
                }
            }
        }
        
        if (!from_stdin && !follow_mode) close(fd);
    }
    
    // Signal completion to workers
    pthread_mutex_lock(&queue_lock);
    all_submitted = 1;
    pthread_cond_broadcast(&queue_cond);
    pthread_mutex_unlock(&queue_lock);
    
    // Wait for workers
    for (int i = 0; i < num_threads; i++) {
        pthread_join(threads[i], NULL);
    }
    
    double end_time = get_time();
    double elapsed = end_time - start_time;
    
    // Flush any remaining output
    if (!count_only) {
        flush_buffer();
    }
    
    // Close output file if opened
    if (output_fd >= 0) close(output_fd);
    
    // Close split-by-level files if opened
    if (split_by_level) {
        for (int i = 0; i < 4; i++) {
            if (level_fds[i] >= 0) close(level_fds[i]);
        }
        print_err("Wrote: debug.txt, info.txt, warn.txt, error.txt\n");
    }
    
    // Results
    print_err("=== Results ===\n");
    if (num_files > 1) {
        print_err("Files:   "); print_num(num_files); print_err("\n");
    }
    print_err("Total:   "); print_num(global_stats.count); print_err("\n");
    print_err("Valid:   "); print_num(global_stats.valid); print_err("\n");
    print_err("Invalid: "); print_num(global_stats.invalid); print_err("\n");
    print_err("--- By Level ---\n");
    print_err("DEBUG:   "); print_num(global_stats.levels[0]); print_err("\n");
    print_err("INFO:    "); print_num(global_stats.levels[1]); print_err("\n");
    print_err("WARN:    "); print_num(global_stats.levels[2]); print_err("\n");
    print_err("ERROR:   "); print_num(global_stats.levels[3]); print_err("\n");
    
    // Print time-based stats if in stats mode
    if (stats_mode > 0 && num_buckets > 0) {
        const char* mode_names[] = {"", "Hourly", "Daily", "Minute", "By Level"};
        print_err("--- Aggregation ("); 
        print_err(mode_names[stats_mode]); 
        print_err(") ---\n");
        
        // By-level mode: simple output
        if (stats_mode == 4) {
            const char* level_names[] = {"DEBUG", "INFO", "WARN", "ERROR"};
            for (int i = 0; i < num_buckets; i++) {
                TimeBucket* b = &time_buckets[i];
                int lvl = (int)b->timestamp;
                if (lvl >= 0 && lvl <= 3) {
                    char line[64];
                    snprintf(line, sizeof(line), "%-6s: %llu\n", level_names[lvl], b->total);
                    print_err(line);
                }
            }
        } else {
            // Sort buckets by timestamp (simple bubble sort, few buckets)
            for (int i = 0; i < num_buckets - 1; i++) {
                for (int j = i + 1; j < num_buckets; j++) {
                    if (time_buckets[j].timestamp < time_buckets[i].timestamp) {
                        TimeBucket tmp = time_buckets[i];
                        time_buckets[i] = time_buckets[j];
                        time_buckets[j] = tmp;
                    }
                }
            }
            
            // Print each bucket
            for (int i = 0; i < num_buckets; i++) {
                TimeBucket* b = &time_buckets[i];
                long long ts = b->timestamp;
                
                // Convert timestamp to readable date/time
                long long days = ts / 86400 + 719468;
                long long era = (days >= 0 ? days : days - 146096) / 146097;
                long long doe = days - era * 146097;
                long long yoe = (doe - doe/1460 + doe/36524 - doe/146096) / 365;
                long long y = yoe + era * 400;
                long long doy = doe - (365*yoe + yoe/4 - yoe/100);
                long long mp = (5*doy + 2)/153;
                long long d = doy - (153*mp+2)/5 + 1;
                long long m = mp < 10 ? mp+3 : mp-9;
                if (m <= 2) y++;
                
                char time_str[32];
                if (stats_mode == 1) {
                    int hour = (ts % 86400) / 3600;
                    snprintf(time_str, sizeof(time_str), "%04lld-%02lld-%02lld %02d:00", y, m, d, hour);
                } else if (stats_mode == 2) {
                    snprintf(time_str, sizeof(time_str), "%04lld-%02lld-%02lld", y, m, d);
                } else {  // minute
                    int hour = (ts % 86400) / 3600;
                    int min = (ts % 3600) / 60;
                    snprintf(time_str, sizeof(time_str), "%04lld-%02lld-%02lld %02d:%02d", y, m, d, hour, min);
                }
                
                char line[128];
                snprintf(line, sizeof(line), "%s  D:%llu I:%llu W:%llu E:%llu (total:%llu)\n",
                         time_str, b->levels[0], b->levels[1], b->levels[2], b->levels[3], b->total);
                print_err(line);
            }
        }
    }
    
    print_err("--- Performance ---\n");
    
    // Calculate and print performance stats
    char perf_buf[128];
    snprintf(perf_buf, sizeof(perf_buf), "Time:    %.2f sec\n", elapsed);
    print_err(perf_buf);
    
    if (elapsed > 0.001) {
        double logs_per_sec = global_stats.count / elapsed;
        double mb_per_sec = (total_read / (1024.0 * 1024.0)) / elapsed;
        snprintf(perf_buf, sizeof(perf_buf), "Speed:   %.1fM logs/sec (%.1f MB/s)\n", 
                 logs_per_sec / 1000000.0, mb_per_sec);
        print_err(perf_buf);
    }
    
    return 0;
}
