// C - Ultra-fast Log Reader with Multi-language Pipeline
// Uses large read() buffers + SIMD + pthreads
// Pipeline: C (reader) -> Zig (parser) -> Rust (processor) -> C++ (formatter)
#include <pthread.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <arm_neon.h>
#include "logentry.h"

// External functions from other languages
extern void parse_log(const char* line, int len, struct LogEntry* entry);    // Zig
extern void process_log(struct LogEntry* entry);                              // Rust  
extern void set_filter(int level_mask, int active);                           // Rust
extern void format_output(struct LogEntry* entry);                            // C++
extern void set_output_format(int format);                                    // C++
extern void flush_buffer(void);                                               // C++

#define MAX_THREADS 12
#define CHUNK_SIZE (64 * 1024 * 1024)  // 64MB chunks

static int num_threads = 8;
static int count_only = 0;  // Skip output if set

// Cache-line aligned stats
typedef struct __attribute__((aligned(64))) {
    unsigned long long count;
    unsigned long long valid;
    unsigned long long invalid;
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
    
    // Use Rust processor for additional processing
    process_log(&entry);
    
    stats->valid++;
    if (entry.level >= 0 && entry.level <= 3) {
        stats->levels[entry.level]++;
    }
    
    // Use C++ formatter for output (if not count-only mode)
    // Formatter checks entry.filtered (set by Rust processor)
    if (!count_only) {
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

int main(int argc, char** argv) {
    const char* filepath = NULL;
    
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
            else { print_err("Error: unknown format (use json,csv,tsv,raw)\n"); return 1; }
        } else if (strcmp(argv[i], "--count-only") == 0) {
            count_only = 1;
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            print_err("Usage: logproc [-t threads] [-l levels] [-o format] [--count-only] <file>\n");
            print_err("  -t N           Use N threads (default: 8, max: 12)\n");
            print_err("  -l LEVELS      Filter by level: DEBUG,INFO,WARN,ERROR\n");
            print_err("  -o FORMAT      Output format: json (default), csv, tsv, raw\n");
            print_err("  --count-only   Skip output, only count\n");
            print_err("\nExamples:\n");
            print_err("  logproc -l ERROR file.txt          # Only ERROR logs\n");
            print_err("  logproc -o csv file.txt            # Output as CSV\n");
            print_err("  logproc -l WARN,ERROR -o tsv file.txt\n");
            return 0;
        } else {
            filepath = argv[i];
        }
    }
    
    if (!filepath) { print_err("Error: file required\n"); return 1; }
    
    int fd = open(filepath, O_RDONLY);
    if (fd < 0) { print_err("Error: cannot open file\n"); return 1; }
    
    struct stat st;
    fstat(fd, &st);
    size_t file_size = st.st_size;
    
    print_err("Processing "); print_num(file_size / (1024*1024)); print_err(" MB with ");
    print_num(num_threads); print_err(" threads...\n");
    
    // Start worker threads
    Stats global_stats = {0};
    pthread_t threads[MAX_THREADS];
    for (int i = 0; i < num_threads; i++) {
        pthread_create(&threads[i], NULL, worker_thread, &global_stats);
    }
    
    // Read file in chunks and submit to workers
    size_t total_read = 0;
    char* overlap = NULL;
    size_t overlap_len = 0;
    
    while (total_read < file_size) {
        size_t to_read = CHUNK_SIZE;
        if (total_read + to_read > file_size) to_read = file_size - total_read;
        
        char* buffer = malloc(to_read + overlap_len + 1);
        
        // Copy overlap from previous chunk
        if (overlap_len > 0) {
            memcpy(buffer, overlap, overlap_len);
            free(overlap);
        }
        
        ssize_t n = read(fd, buffer + overlap_len, to_read);
        if (n <= 0) { free(buffer); break; }
        
        size_t buf_size = overlap_len + n;
        total_read += n;
        
        // Find last newline to handle partial lines
        size_t last_nl = buf_size;
        while (last_nl > 0 && buffer[last_nl - 1] != '\n') last_nl--;
        
        if (last_nl == 0 && total_read < file_size) {
            // No newline found, buffer entire thing as overlap
            overlap = buffer;
            overlap_len = buf_size;
            continue;
        }
        
        // Save partial line for next chunk
        if (last_nl < buf_size && total_read < file_size) {
            overlap_len = buf_size - last_nl;
            overlap = malloc(overlap_len);
            memcpy(overlap, buffer + last_nl, overlap_len);
            buf_size = last_nl;
        } else {
            overlap = NULL;
            overlap_len = 0;
        }
        
        // Submit work item
        WorkItem* item = malloc(sizeof(WorkItem));
        item->buffer = buffer;
        item->size = buf_size;
        item->has_partial_start = 0;
        
        pthread_mutex_lock(&queue_lock);
        work_queue[queue_tail++ % 1024] = item;
        pthread_cond_signal(&queue_cond);
        pthread_mutex_unlock(&queue_lock);
    }
    
    // Handle final overlap
    if (overlap_len > 0) {
        WorkItem* item = malloc(sizeof(WorkItem));
        item->buffer = overlap;
        item->size = overlap_len;
        item->has_partial_start = 0;
        
        pthread_mutex_lock(&queue_lock);
        work_queue[queue_tail++ % 1024] = item;
        pthread_cond_signal(&queue_cond);
        pthread_mutex_unlock(&queue_lock);
    }
    
    // Signal completion
    pthread_mutex_lock(&queue_lock);
    all_submitted = 1;
    pthread_cond_broadcast(&queue_cond);
    pthread_mutex_unlock(&queue_lock);
    
    // Wait for workers
    for (int i = 0; i < num_threads; i++) {
        pthread_join(threads[i], NULL);
    }
    
    close(fd);
    
    // Flush any remaining output
    if (!count_only) {
        flush_buffer();
    }
    
    // Results
    print_err("=== Results ===\n");
    print_err("Total:   "); print_num(global_stats.count); print_err("\n");
    print_err("Valid:   "); print_num(global_stats.valid); print_err("\n");
    print_err("Invalid: "); print_num(global_stats.invalid); print_err("\n");
    print_err("--- By Level ---\n");
    print_err("DEBUG:   "); print_num(global_stats.levels[0]); print_err("\n");
    print_err("INFO:    "); print_num(global_stats.levels[1]); print_err("\n");
    print_err("WARN:    "); print_num(global_stats.levels[2]); print_err("\n");
    print_err("ERROR:   "); print_num(global_stats.levels[3]); print_err("\n");
    
    return 0;
}
