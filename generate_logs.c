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
    
    // Build output: "YYYY-MM-DD HH:MM:SS LEVEL message\n"
    int year = 2024 + fast_rand(2);
    int month = 1 + fast_rand(12);
    int day = 1 + fast_rand(28);
    int hour = fast_rand(24);
    int min = fast_rand(60);
    int sec = fast_rand(60);
    
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
        fprintf(stderr, "Usage: %s <count> [output_file]\n", argv[0]);
        fprintf(stderr, "  count       - Number of log entries (supports K, M, B suffixes)\n");
        fprintf(stderr, "  output_file - Output file (default: stdout)\n");
        fprintf(stderr, "\nExamples:\n");
        fprintf(stderr, "  %s 1M > logs.txt      # 1 million entries\n", argv[0]);
        fprintf(stderr, "  %s 1B logs.txt        # 1 billion entries\n", argv[0]);
        return 1;
    }

    // Parse count with K/M/B suffix
    char* endptr;
    uint64_t count = strtoull(argv[1], &endptr, 10);
    if (*endptr == 'K' || *endptr == 'k') count *= 1000ULL;
    else if (*endptr == 'M' || *endptr == 'm') count *= 1000000ULL;
    else if (*endptr == 'B' || *endptr == 'b') count *= 1000000000ULL;

    // Open output
    FILE* out = stdout;
    if (argc >= 3) {
        out = fopen(argv[2], "w");
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
