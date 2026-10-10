// C - Ultra-fast Log Reader with Multi-language Pipeline
// Uses a pool of read() buffers + SIMD + pthreads
// Pipeline: C (reader) -> Zig (parser) -> Rust (processor) -> C++ (formatter)
#include <pthread.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <unistd.h>
#include <string.h>
#include <strings.h>
#include <stdio.h>
#include <stdlib.h>
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#endif
#include "logentry.h"

// Get current time in seconds
static double get_time(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec / 1000000.0;
}

// Write all of it to stderr: the aggregation can be many megabytes, and a
// partial write must not lose bucket lines
static void write_err(const char* s, size_t len) {
    while (len > 0) {
        ssize_t n = write(2, s, len);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && errno == EAGAIN) {
            struct pollfd pfd = {2, POLLOUT, 0};
            poll(&pfd, 1, -1);
            continue;
        }
        if (n <= 0) return;
        s += n;
        len -= (size_t)n;
    }
}
static void print_err(const char* s) { write_err(s, strlen(s)); }
static void print_num(unsigned long long n) {
    char buf[24]; snprintf(buf, sizeof(buf), "%llu", n);
    print_err(buf);
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
extern void finish_output(void);                                              // C++
extern int output_failed(void);                                               // C++

// Parse 'YYYY-MM-DD' or 'YYYY-MM-DD HH:MM:SS' (UTC) to a unix timestamp.
// Digits, separators and calendar ranges are checked the way the parser
// checks a log line. Returns 0 if str is anything else.
static int parse_datetime(const char* str, long long* timestamp) {
    static const char shape[] = "dddd-dd-dd dd:dd:dd";
    static const int month_days[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    size_t len = strlen(str);
    if (len != 10 && len != 19) return 0;
    for (size_t i = 0; i < len; i++) {
        if (shape[i] == 'd' ? (str[i] < '0' || str[i] > '9') : (str[i] != shape[i])) return 0;
    }
    
    int year = (str[0]-'0')*1000 + (str[1]-'0')*100 + (str[2]-'0')*10 + (str[3]-'0');
    int month = (str[5]-'0')*10 + (str[6]-'0');
    int day = (str[8]-'0')*10 + (str[9]-'0');
    int hour = 0, min = 0, sec = 0;
    if (len == 19) {
        hour = (str[11]-'0')*10 + (str[12]-'0');
        min = (str[14]-'0')*10 + (str[15]-'0');
        sec = (str[17]-'0')*10 + (str[18]-'0');
    }
    int leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    if (month < 1 || month > 12) return 0;
    if (day < 1 || day > month_days[month - 1] + (month == 2 && leap)) return 0;
    if (hour > 23 || min > 59 || sec > 59) return 0;
    
    // Convert to timestamp (assumes UTC)
    int y = year, m = month;
    if (m <= 2) { y -= 1; m += 12; }
    long long era = (y >= 0 ? y : y - 399) / 400;  // Rounds down: y is -1 early in year 0000
    long long yoe = y - era * 400;
    long long doy = (153 * (m - 3) + 2) / 5 + day - 1;
    long long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    long long days = era * 146097 + doe - 719468;
    *timestamp = days * 86400 + hour * 3600 + min * 60 + sec;
    return 1;
}

#define MAX_THREADS 12
#define CHUNK_SIZE (1024 * 1024)  // 1MB read buffers; a longer line is processed truncated to this
#define MAX_ITEMS (2 * MAX_THREADS + 2)

static int num_threads = 8;
static int count_only = 0;  // Skip output if set
static int stats_mode = 0;  // 0=off, 1=hourly, 2=daily, 3=minute, 4=by-level
static int split_by_level = 0;  // Write separate files per level

// Bucket width in seconds, indexed by stats_mode (by-level uses one bucket)
static const long long bucket_seconds[] = {0, 3600, 86400, 60, 0};

#define BLOCK_BUCKETS 64  // Consecutive time buckets that are counted together in a block

// A block of time buckets
typedef struct {
    unsigned char counts[BLOCK_BUCKETS][4];  // Matched entries per bucket and level, modulo 256
    unsigned long long (*carried)[4];        // What the counts have wrapped past; NULL until one does
} BucketBlock;

// An entry of a table's hash index
typedef struct {
    long long key;       // Block number: floor(bucket number / BLOCK_BUCKETS)
    BucketBlock* block;  // NULL in a free slot
} BlockSlot;

// A count that is still to be raised
typedef struct {
    BucketBlock* block;  // NULL: none
    int index;           // 4 * bucket offset in the block + level
} PendingCount;

#define FIRST_BLOCKS 16   // Blocks in a table's first segment
#define MAX_SEGMENTS 32   // Room for 2^36 blocks, more than memory holds
#define PENDING_COUNTS 8  // Counts raised later, see record_bucket()

// The buckets of one worker thread. Each worker fills its own table, so no
// lock is taken per line; the tables are merged when the results are printed.
// A bucket is found through the hash index of its block and then directly:
// buckets close in time share an index entry, and a bucket takes four bytes
// until one of its counts passes 255. The blocks live in segments that double
// in size and never move.
typedef struct {
    BucketBlock* segments[MAX_SEGMENTS];  // Segment s holds FIRST_BLOCKS << s blocks
    int num_segments;
    BucketBlock* unused;  // Next unused block of the last segment
    BlockSlot* slots;     // Hash index (open addressing); a sorted run once the worker is done
    size_t num_slots;     // Power of two, more than twice the capacity
    size_t count;         // Blocks in use
    size_t capacity;      // Blocks allocated
    int shift;            // Hash bits to drop: 64 - log2(num_slots)
    PendingCount pending[PENDING_COUNTS];
    unsigned int next_pending;
} BucketTable;

static BucketTable bucket_tables[MAX_THREADS];  // Each stored by its worker when that is done

// Cache-line aligned stats
typedef struct __attribute__((aligned(64))) {
    unsigned long long count;
    unsigned long long valid;
    unsigned long long invalid;
    unsigned long long matched;  // Entries that passed all filters
    unsigned long long levels[4];
} Stats;

// Work item: one read buffer holding whole lines, recycled through the pool
typedef struct WorkItem {
    struct WorkItem* next;
    char* buffer;  // CHUNK_SIZE bytes
    size_t size;   // Bytes to process
} WorkItem;

#if defined(__ARM_NEON) || defined(__ARM_NEON__)
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
#else
// Portable newline finder (no NEON on this target)
static inline const char* find_newline(const char* p, const char* end) {
    const char* nl = memchr(p, '\n', (size_t)(end - p));
    return nl ? nl : end;
}
#endif

static inline size_t bucket_slot(int shift, long long key) {
    // Fibonacci hashing: block numbers are consecutive or evenly spaced
    return (size_t)(((unsigned long long)key * 0x9E3779B97F4A7C15ULL) >> shift);
}

// Out of memory on a worker thread, with the others still running: leave at
// once (stats mode writes no records, so nothing is left unflushed)
static void buckets_out_of_memory(void) {
    print_err("Error: out of memory\n");
    _exit(1);
}

// Add a segment to a full table and move its blocks to a larger hash index
static void grow_buckets(BucketTable* t) {
    size_t seg_size = (size_t)FIRST_BLOCKS << t->num_segments;
    size_t num_slots = 4 * seg_size;
    BucketBlock* segment = NULL;
    BlockSlot* slots = NULL;
    if (t->num_segments < MAX_SEGMENTS) {
        segment = calloc(seg_size, sizeof(BucketBlock));
        slots = calloc(num_slots, sizeof(BlockSlot));
    }
    if (!segment || !slots) buckets_out_of_memory();
    int shift = __builtin_clzll(num_slots - 1);
    for (size_t i = 0; i < t->num_slots; i++) {
        if (!t->slots[i].block) continue;
        size_t slot = bucket_slot(shift, t->slots[i].key);
        while (slots[slot].block) slot = (slot + 1) & (num_slots - 1);
        slots[slot] = t->slots[i];
    }
    free(t->slots);
    t->segments[t->num_segments++] = segment;
    t->unused = segment;
    t->slots = slots;
    t->num_slots = num_slots;
    t->capacity += seg_size;
    t->shift = shift;
}

// Raise a count. One that wraps to zero hands its 256 entries to the wide
// counters of the block.
static inline void add_count(BucketBlock* b, int index) {
    if (++b->counts[index >> 2][index & 3] != 0) return;
    if (!b->carried) {
        b->carried = calloc(BLOCK_BUCKETS, sizeof(*b->carried));
        if (!b->carried) buckets_out_of_memory();
    }
    b->carried[index >> 2][index & 3] += 256;
}

// Record to time bucket (for stats mode), in the calling worker's table
static inline void record_bucket(BucketTable* t, long long timestamp, int level) {
    if (level < 0 || level > 3) return;  // No valid entry has another level
    
    // Floor division: timestamps before 1970 are negative
    long long width = bucket_seconds[stats_mode];
    long long bucket = 0;
    if (width) {
        bucket = timestamp / width;
        if (timestamp % width < 0) bucket--;
    }
    long long key = bucket / BLOCK_BUCKETS;
    int offset = (int)(bucket % BLOCK_BUCKETS);
    if (offset < 0) { offset += BLOCK_BUCKETS; key--; }
    
    // Find or create the block
    if (t->count == t->capacity) grow_buckets(t);
    size_t slot = bucket_slot(t->shift, key);
    BlockSlot* s;
    while (1) {
        s = &t->slots[slot];
        if (!s->block) {
            s->key = key;
            s->block = t->unused++;
            t->count++;
            break;
        }
        if (s->key == key) break;
        slot = (slot + 1) & (t->num_slots - 1);
    }
    
    // With many buckets the count is rarely in the cache. Ask for it now and
    // raise it a few entries later, in place of the count that has waited
    // longest, so that the worker does not sit out the cache miss.
    PendingCount* p = &t->pending[t->next_pending++ % PENDING_COUNTS];
    if (p->block) add_count(p->block, p->index);
    p->block = s->block;
    p->index = 4 * offset + level;
    __builtin_prefetch(&s->block->counts[offset][level], 1);
}

static int compare_slots(const void* a, const void* b) {
    long long x = ((const BlockSlot*)a)->key;
    long long y = ((const BlockSlot*)b)->key;
    return (x > y) - (x < y);
}

// A worker is done: raise the counts still pending and turn the hash index
// into the sorted run of blocks that next_block() merges
static void finish_buckets(BucketTable* t) {
    for (int i = 0; i < PENDING_COUNTS; i++) {
        if (t->pending[i].block) add_count(t->pending[i].block, t->pending[i].index);
    }
    size_t n = 0;
    for (size_t i = 0; i < t->num_slots; i++) {
        if (t->slots[i].block) t->slots[n++] = t->slots[i];
    }
    if (n > 1) qsort(t->slots, n, sizeof(BlockSlot), compare_slots);
}

// A sorted run of blocks: those of one worker's table
typedef struct {
    long long key;  // Of the next block
    const BlockSlot* next;
    const BlockSlot* end;
} BucketRun;

// The runs form a binary min-heap on the key of their next block
static void sift_run(BucketRun* runs, int n, int i) {
    while (1) {
        int child = 2 * i + 1;
        if (child >= n) break;
        if (child + 1 < n && runs[child + 1].key < runs[child].key) child++;
        if (runs[i].key <= runs[child].key) break;
        BucketRun tmp = runs[i];
        runs[i] = runs[child];
        runs[child] = tmp;
        i = child;
    }
}

// Collect every worker's sorted blocks as a heap of runs; returns their number
static int collect_runs(BucketRun* runs) {
    int n = 0;
    for (int t = 0; t < num_threads; t++) {
        const BucketTable* tab = &bucket_tables[t];
        if (tab->count == 0) continue;
        runs[n].key = tab->slots[0].key;
        runs[n].next = tab->slots;
        runs[n].end = tab->slots + tab->count;
        n++;
    }
    for (int i = n / 2 - 1; i >= 0; i--) sift_run(runs, n, i);
    return n;
}

// The buckets of one block, added up over the workers
typedef struct {
    long long key;
    unsigned short counts[BLOCK_BUCKETS][4];       // Sums of the byte counts: at most 255 per worker
    unsigned long long carried[BLOCK_BUCKETS][4];  // Sums of the carried counts
    int any_carried;                               // 0: carried is all zero
} BlockSum;

#define MERGE_AHEAD 4  // Blocks that next_block() prefetches ahead in a run

// Merge step: add up the earliest block left in the runs over every worker
// that has it. Returns 0 when none is left.
static int next_block(BucketRun* runs, int* n, BlockSum* sum) {
    if (*n == 0) return 0;
    memset(sum->counts, 0, sizeof(sum->counts));
    if (sum->any_carried) memset(sum->carried, 0, sizeof(sum->carried));
    sum->any_carried = 0;
    sum->key = runs[0].key;
    while (*n > 0 && runs[0].key == sum->key) {
        const BucketBlock* b = (runs[0].next++)->block;
        // A table's blocks lie in the order they were first seen, not in key
        // order: ask early for the one this run reaches a few steps from now
        if (runs[0].end - runs[0].next > MERGE_AHEAD) {
            const char* ahead = (const char*)runs[0].next[MERGE_AHEAD].block;
            for (size_t i = 0; i < sizeof(BucketBlock); i += 64) __builtin_prefetch(ahead + i);
        }
        for (int i = 0; i < BLOCK_BUCKETS; i++) {
            for (int level = 0; level < 4; level++) sum->counts[i][level] += b->counts[i][level];
        }
        if (b->carried) {
            for (int i = 0; i < BLOCK_BUCKETS; i++) {
                for (int level = 0; level < 4; level++) sum->carried[i][level] += b->carried[i][level];
            }
            sum->any_carried = 1;
        }
        if (runs[0].next == runs[0].end) runs[0] = runs[--*n];
        else runs[0].key = runs[0].next->key;
        sift_run(runs, *n, 0);
    }
    return 1;
}

// Append n in decimal, zero-padded to `width` digits (snprintf is too slow
// for the millions of bucket lines minute mode can print)
static char* put_num(char* p, unsigned long long n, int width) {
    char digits[24];
    int len = 0;
    do { digits[len++] = (char)('0' + n % 10); n /= 10; } while (n);
    while (width-- > len) *p++ = '0';
    while (len > 0) *p++ = digits[--len];
    return p;
}

// Append a count: most are a single digit
static inline char* put_count(char* p, unsigned long long n) {
    if (n >= 10) return put_num(p, n, 1);
    *p = (char)('0' + n);
    return p + 1;
}

// Append the date of a day number (days since 1970-01-01) as 'YYYY-MM-DD'
static char* put_date(char* p, long long days) {
    days += 719468;
    long long era = (days >= 0 ? days : days - 146096) / 146097;
    long long doe = days - era * 146097;
    long long yoe = (doe - doe/1460 + doe/36524 - doe/146096) / 365;
    long long y = yoe + era * 400;
    long long doy = doe - (365*yoe + yoe/4 - yoe/100);
    long long mp = (5*doy + 2)/153;
    long long d = doy - (153*mp+2)/5 + 1;
    long long m = mp < 10 ? mp+3 : mp-9;
    if (m <= 2) y++;
    
    p = put_num(p, (unsigned long long)y, 4); *p++ = '-';
    p = put_num(p, (unsigned long long)m, 2); *p++ = '-';
    return put_num(p, (unsigned long long)d, 2);
}

// Print the time buckets of all workers in time order, one line each
// ('YYYY-MM-DD HH:MM  D:n I:n W:n E:n (total:n)'), many lines per write()
static void print_buckets(BucketRun* runs, int num_runs) {
    long long width = bucket_seconds[stats_mode];
    long long per_day = 86400 / width;
    long long date_day = LLONG_MIN;  // The day that `date` holds
    char date[10];
    char out[65536];
    char* p = out;
    BlockSum sum = {0};
    
    while (next_block(runs, &num_runs, &sum)) {
        for (int i = 0; i < BLOCK_BUCKETS; i++) {
            unsigned long long levels[4], total = 0;
            for (int level = 0; level < 4; level++) {
                levels[level] = sum.counts[i][level] + sum.carried[i][level];
                total += levels[level];
            }
            if (!total) continue;
            if (p + 256 > out + sizeof(out)) { write_err(out, (size_t)(p - out)); p = out; }
            
            // Split the bucket number into days since the epoch and time of
            // day, rounding down so that dates before 1970 come out right
            long long bucket = sum.key * BLOCK_BUCKETS + i;
            long long days = bucket / per_day;
            long long rem = bucket % per_day;
            if (rem < 0) { rem += per_day; days--; }
            int secs = (int)(rem * width);
            
            // The buckets come in time order, and converting the date costs
            // more than the rest of the line: do it once per day
            if (days != date_day) {
                put_date(date, days);
                date_day = days;
            }
            memcpy(p, date, sizeof(date));
            p += sizeof(date);
            if (stats_mode != 2) {  // hourly: HH:00, minute: HH:MM
                *p++ = ' ';
                p = put_num(p, (unsigned long long)(secs / 3600), 2); *p++ = ':';
                p = put_num(p, (unsigned long long)(secs % 3600 / 60), 2);
            }
            *p++ = ' ';
            for (int level = 0; level < 4; level++) {
                *p++ = ' '; *p++ = "DIWE"[level]; *p++ = ':';
                p = put_count(p, levels[level]);
            }
            memcpy(p, " (total:", 8);
            p = put_count(p + 8, total);
            *p++ = ')'; *p++ = '\n';
        }
    }
    write_err(out, (size_t)(p - out));
}

// Fast inline validation + level detection using multi-language pipeline
static inline void process_line(const char* line, int len, Stats* stats, BucketTable* buckets) {
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
            record_bucket(buckets, entry.timestamp, entry.level);
        }
    }
    
    // Use C++ formatter for output (if not count-only mode and not stats mode)
    if (!count_only && stats_mode == 0) {
        format_output(&entry);
    }
}

// Process a buffer
static void process_buffer(const char* buf, size_t size, Stats* stats, BucketTable* buckets) {
    const char* p = buf;
    const char* end = buf + size;
    
    while (p < end) {
        const char* nl = find_newline(p, end);
        int len = (int)(nl - p);
        if (len > 0) process_line(p, len, stats, buckets);
        else if (len == 0) { stats->count++; stats->invalid++; }
        p = nl + 1;
    }
}

// Thread pool for parallel processing. The items come from a fixed pool, so
// the queue cannot overflow and the reader blocks while the workers hold them
// all (back-pressure): memory stays bounded whatever the input size.
static pthread_mutex_t queue_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t queue_cond = PTHREAD_COND_INITIALIZER;  // Work queued, or all submitted
static pthread_cond_t free_cond = PTHREAD_COND_INITIALIZER;   // An item returned to the pool
static WorkItem item_pool[MAX_ITEMS];
static WorkItem* free_items = NULL;
static WorkItem* queue_head = NULL;
static WorkItem* queue_tail = NULL;
static int busy_items = 0;  // Submitted and not yet returned to the pool
static int all_submitted = 0;
static Stats global_stats;  // Sum over the workers, each adding its own under queue_lock

// Take an empty item from the pool, waiting for a worker to return one
static WorkItem* get_item(void) {
    pthread_mutex_lock(&queue_lock);
    while (!free_items) pthread_cond_wait(&free_cond, &queue_lock);
    WorkItem* item = free_items;
    free_items = item->next;
    pthread_mutex_unlock(&queue_lock);
    return item;
}

// Return an item to the pool (queue_lock must be held)
static void release_item(WorkItem* item) {
    item->next = free_items;
    free_items = item;
    pthread_cond_signal(&free_cond);
}

// Queue the first `size` bytes of an item for the workers
static void submit_item(WorkItem* item, size_t size) {
    item->size = size;
    item->next = NULL;
    pthread_mutex_lock(&queue_lock);
    if (queue_tail) queue_tail->next = item;
    else queue_head = item;
    queue_tail = item;
    busy_items++;
    pthread_cond_signal(&queue_cond);
    pthread_mutex_unlock(&queue_lock);
}

// Follow mode: wait until the workers have processed everything submitted,
// then flush, so that appended lines come out at once and in order
static void finish_batch(void) {
    pthread_mutex_lock(&queue_lock);
    while (busy_items > 0) pthread_cond_wait(&free_cond, &queue_lock);
    pthread_mutex_unlock(&queue_lock);
    if (!count_only && stats_mode == 0) flush_buffer();
}

// Set by SIGINT or SIGTERM in follow mode
static volatile sig_atomic_t stop_requested = 0;

static void request_stop(int sig) {
    (void)sig;
    stop_requested = 1;
}

static void* worker_thread(void* arg) {
    // What is written for every line stays on this thread's stack, away from
    // the cache lines that the other threads read and write
    BucketTable buckets = {0};  // This worker's --stats table
    Stats local = {0};
    
    pthread_mutex_lock(&queue_lock);
    while (1) {
        while (!queue_head && !all_submitted) {
            pthread_cond_wait(&queue_cond, &queue_lock);
        }
        WorkItem* item = queue_head;
        if (!item) break;
        queue_head = item->next;
        if (!queue_head) queue_tail = NULL;
        pthread_mutex_unlock(&queue_lock);
        
        process_buffer(item->buffer, item->size, &local, &buckets);
        
        pthread_mutex_lock(&queue_lock);
        busy_items--;
        release_item(item);
        if (busy_items == 0 && !count_only && stats_mode == 0) {
            // The workers have caught up with the reader: write out what is
            // buffered, so that records from a slow pipe do not wait for
            // the output buffer to fill
            pthread_mutex_unlock(&queue_lock);
            flush_buffer();
            pthread_mutex_lock(&queue_lock);
        }
    }
    
    // Merge to global
    global_stats.count += local.count;
    global_stats.valid += local.valid;
    global_stats.invalid += local.invalid;
    global_stats.matched += local.matched;
    for (int i = 0; i < 4; i++) global_stats.levels[i] += local.levels[i];
    pthread_mutex_unlock(&queue_lock);
    
    // Sorting this worker's blocks for the merge is done here, by all
    // workers in parallel
    finish_buckets(&buckets);
    *(BucketTable*)arg = buckets;
    
    return NULL;
}

// The settings that the command line and a --config file share. The numbers
// index setting_info and are the bit numbers in the masks of given settings.
enum { SET_THREADS, SET_LEVELS, SET_FORMAT, SET_PATTERN, SET_STATS, SET_AFTER, SET_BEFORE, NUM_SETTINGS };

static const struct {
    const char* flag;      // Command-line option
    const char* key;       // Config file key
    const char* expected;  // For the error about an invalid value
} setting_info[NUM_SETTINGS] = {
    {"-t", "threads", "an integer"},
    {"-l", "levels", "a comma-separated list of DEBUG, INFO, WARN, ERROR"},
    {"-o", "format", "json, jsonl, csv, tsv or raw"},
    {"-m", "pattern", "any text"},
    {"--stats", "stats", "hourly, daily, minute or by-level"},
    {"--after", "after", "YYYY-MM-DD or 'YYYY-MM-DD HH:MM:SS'"},
    {"--before", "before", "YYYY-MM-DD or 'YYYY-MM-DD HH:MM:SS'"},
};

typedef struct {
    int threads;
    int level_mask;       // bit0=DEBUG, bit1=INFO, bit2=WARN, bit3=ERROR
    int format;           // Number for set_output_format()
    const char* pattern;  // Empty means no message filter
    int stats;            // Value for stats_mode
    long long after;      // Time filter, inclusive at both ends
    long long before;
} Settings;

// Position of value in a list of names, or -1
static int find_name(const char* value, const char* const* names, int count) {
    for (int i = 0; i < count; i++) {
        if (strcmp(value, names[i]) == 0) return i;
    }
    return -1;
}

// Check the value of one setting and store it. Returns 0 if it is not valid.
static int set_value(Settings* s, int which, const char* value) {
    static const char* const levels[] = {"DEBUG", "INFO", "WARN", "ERROR"};
    static const char* const formats[] = {"json", "csv", "tsv", "raw", "jsonl"};
    static const char* const stats[] = {"hourly", "daily", "minute", "by-level"};
    
    switch (which) {
    case SET_THREADS: {
        char* end;
        long n = strtol(value, &end, 10);
        if (end == value || *end) return 0;
        s->threads = n < 1 ? 1 : n > MAX_THREADS ? MAX_THREADS : (int)n;
        return 1;
    }
    case SET_LEVELS: {
        // Names in any case, blanks allowed around them. An unknown or
        // empty name is an error: it must not end up as a filter that
        // silently drops everything.
        int mask = 0;
        const char* p = value;
        while (1) {
            while (*p == ' ' || *p == '\t') p++;
            size_t len = strcspn(p, ", \t");
            int level = 0;
            while (level < 4 && (strlen(levels[level]) != len || strncasecmp(p, levels[level], len) != 0)) level++;
            if (level == 4) return 0;
            mask |= 1 << level;
            p += len;
            while (*p == ' ' || *p == '\t') p++;
            if (!*p) break;
            if (*p++ != ',') return 0;
        }
        s->level_mask = mask;
        return 1;
    }
    case SET_FORMAT: {
        int format = find_name(value, formats, 5);
        if (format < 0) return 0;
        s->format = format;
        return 1;
    }
    case SET_PATTERN:
        s->pattern = value;
        return 1;
    case SET_STATS: {
        int mode = find_name(value, stats, 4);
        if (mode < 0) return 0;
        s->stats = mode + 1;
        return 1;
    }
    case SET_AFTER:
        return parse_datetime(value, &s->after);
    default:  // SET_BEFORE
        return parse_datetime(value, &s->before);
    }
}

// Rest of an error line about an invalid value (name: the option or the key)
static void print_bad_value(const char* name, const char* value, int which) {
    print_err("invalid value '"); print_err(value); print_err("' for "); print_err(name);
    print_err(" (expected "); print_err(setting_info[which].expected); print_err(")\n");
}

static int is_blank(char c) {
    return c == ' ' || c == '\t' || c == '\r' || c == '\n';
}

// Cut blanks and the line ending (LF or CRLF) off both ends of [s, end);
// returns the new start
static char* trim(char* s, char* end) {
    while (s < end && is_blank(*s)) s++;
    while (end > s && is_blank(end[-1])) end--;
    *end = 0;
    return s;
}

// Load 'key = value' lines from a config file. Settings given on the command
// line (cli_given) keep their value, but the file's values are checked all
// the same; the settings taken from the file are added to *given.
// Returns 0 after reporting an error.
static int load_config(const char* path, Settings* s, int cli_given, int* given) {
    static char* pattern = NULL;  // The line buffer is reused: the pattern needs a copy
    FILE* cfg = fopen(path, "r");
    if (!cfg) {
        print_err("Error: cannot open config file: "); print_err(path); print_err("\n");
        return 0;
    }
    
    char* line = NULL;
    size_t cap = 0;
    ssize_t len;
    unsigned long long lineno = 0;
    int ok = 1;
    
    while (ok && (len = getline(&line, &cap, cfg)) >= 0) {
        lineno++;
        char* key = trim(line, line + len);
        // Skip empty lines and comments
        if (!key[0] || key[0] == '#') continue;
        
        // Parse key=value
        char* eq = strchr(key, '=');
        char* val = eq ? trim(eq + 1, key + strlen(key)) : NULL;
        if (eq) trim(key, eq);
        int which = 0;
        while (eq && which < NUM_SETTINGS && strcmp(key, setting_info[which].key) != 0) which++;
        
        // Apply config
        Settings ignored;
        int from_cli = which < NUM_SETTINGS && (cli_given >> which & 1);
        if (!eq || which == NUM_SETTINGS || !set_value(from_cli ? &ignored : s, which, val)) {
            print_err("Error: "); print_err(path); print_err(":"); print_num(lineno); print_err(": ");
            if (!eq) print_err("expected 'key = value'\n");
            else if (which == NUM_SETTINGS) { print_err("unknown key '"); print_err(key); print_err("'\n"); }
            else print_bad_value(key, val, which);
            ok = 0;
        } else if (!from_cli) {
            if (which == SET_PATTERN) {
                free(pattern);
                s->pattern = pattern = strdup(val);
                if (!pattern) { print_err("Error: out of memory\n"); ok = 0; }
            }
            *given |= 1 << which;
        }
    }
    if (ok && ferror(cfg)) {
        print_err("Error: cannot read config file: "); print_err(path); print_err("\n");
        ok = 0;
    }
    free(line);
    fclose(cfg);
    return ok;
}

static void print_help(void) {
    print_err("Usage: logproc [OPTIONS] [FILE...]\n\n");
    print_err("Reads the FILEs in order; '-' or no FILE at all means stdin.\n");
    print_err("Lines look like 'YYYY-MM-DD HH:MM:SS LEVEL message' (times are UTC).\n\n");
    print_err("Options:\n");
    print_err("  -t N             Use N threads (default: 8; clamped to 1..12)\n");
    print_err("  -l LEVELS        Filter by level: comma-separated DEBUG,INFO,WARN,ERROR\n");
    print_err("                   (any case)\n");
    print_err("  -m PATTERN       Filter messages containing PATTERN (ignoring case);\n");
    print_err("                   an empty PATTERN means no filter\n");
    print_err("  --after DATE     Only logs at or after DATE: YYYY-MM-DD (midnight)\n");
    print_err("                   or 'YYYY-MM-DD HH:MM:SS'\n");
    print_err("  --before DATE    Only logs at or before DATE\n");
    print_err("  -o FORMAT        Output format: json (default, one array), jsonl, csv,\n");
    print_err("                   tsv, raw\n");
    print_err("  -O FILE          Write output to FILE instead of stdout\n");
    print_err("  --split-by-level Write separate files: debug.txt, info.txt, etc.\n");
    print_err("  --stats MODE     Aggregate the matching logs instead of writing them:\n");
    print_err("                   hourly, daily, minute, by-level\n");
    print_err("  --count-only     Skip output, only count\n");
    print_err("  -f, --follow     Follow the last FILE for new lines (like tail -f);\n");
    print_err("                   Ctrl+C stops and prints the results; json output\n");
    print_err("                   becomes jsonl\n");
    print_err("  --config FILE    Load settings from FILE: lines 'key = value' with the\n");
    print_err("                   keys levels, format, pattern, stats, after, before,\n");
    print_err("                   threads; '#' starts a comment line. Options given on\n");
    print_err("                   the command line win. One config file at most\n");
    print_err("  -h, --help       Show this help\n");
    print_err("  --               End of options: the rest are FILEs\n");
    print_err("\nExit status: 0 on success; 1 for a usage or config error, or when an\n");
    print_err("input could not be read or the output could not be written.\n");
    print_err("\nExamples:\n");
    print_err("  logproc -l ERROR file.txt                  # Only ERROR logs\n");
    print_err("  logproc --stats hourly file.txt            # Hourly breakdown\n");
    print_err("  logproc --split-by-level file.txt          # Separate files\n");
    print_err("  logproc -o jsonl file.txt                  # Streaming JSON Lines\n");
    print_err("  logproc -f -l WARN,ERROR app.log           # Watch a growing file\n");
    print_err("  cat file.txt | logproc                     # Read from stdin\n");
}

int main(int argc, char** argv) {
    // The input files are collected at the front of argv itself, so there is
    // no limit on their number
    char** filepaths = argv + 1;
    int num_files = 0;
    const char* output_path = NULL;
    const char* config_path = NULL;
    Settings settings = {num_threads, 0, 0, "", 0, LLONG_MIN, LLONG_MAX};  // LLONG_MIN: dates before 1970 are negative
    int given = 0;         // Settings given on the command line or in the config file
    int follow_mode = 0;   // -f flag for tail-like following
    int options_done = 0;  // After "--"
    
    for (int i = 1; i < argc; i++) {
        const char* arg = argv[i];
        if (options_done || arg[0] != '-' || !arg[1]) {
            // Collect input files ("-" is stdin)
            filepaths[num_files++] = argv[i];
        } else if (strcmp(arg, "--") == 0) {
            options_done = 1;
        } else if (strcmp(arg, "-f") == 0 || strcmp(arg, "--follow") == 0) {
            follow_mode = 1;
        } else if (strcmp(arg, "--split-by-level") == 0) {
            split_by_level = 1;
        } else if (strcmp(arg, "--count-only") == 0) {
            count_only = 1;
        } else if (strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0) {
            print_help();
            return 0;
        } else {
            // The remaining options take a value
            int which = 0;
            while (which < NUM_SETTINGS && strcmp(arg, setting_info[which].flag) != 0) which++;
            int is_output = strcmp(arg, "-O") == 0;
            int is_config = strcmp(arg, "--config") == 0;
            if (which == NUM_SETTINGS && !is_output && !is_config) {
                print_err("Error: unknown option '"); print_err(arg); print_err("' (see --help)\n");
                return 1;
            }
            if (i + 1 >= argc) {
                print_err("Error: option '"); print_err(arg); print_err("' needs a value\n");
                return 1;
            }
            const char* value = argv[++i];
            if (is_config && config_path) {
                // Only the last file would be read, the others not even checked
                print_err("Error: option '--config' given more than once\n");
                return 1;
            }
            if (is_output) output_path = value;
            else if (is_config) config_path = value;
            else if (set_value(&settings, which, value)) given |= 1 << which;
            else {
                print_err("Error: "); print_bad_value(arg, value, which);
                return 1;
            }
        }
    }
    
    // Load config file if specified; what the command line gave wins
    if (config_path && !load_config(config_path, &settings, given, &given)) return 1;
    
    if (settings.after > settings.before) {
        print_err("Error: --after is later than --before\n");
        return 1;
    }
    if (config_path) {
        print_err("Loaded config: "); print_err(config_path); print_err("\n");
    }
    
    // Only a file can be followed, and only the last input is
    if (follow_mode && (num_files == 0 || strcmp(filepaths[num_files - 1], "-") == 0)) {
        print_err("Note: -f is ignored, the last input is stdin\n");
        follow_mode = 0;
    }
    // A followed file has no end, so a JSON array would never be closed
    if (follow_mode && settings.format == 0) {
        settings.format = 4;
        if (!count_only && settings.stats == 0 && !split_by_level) {
            print_err("Note: with -f, json output is written as jsonl (one object per line)\n");
        }
    }
    
    num_threads = settings.threads;
    stats_mode = settings.stats;
    set_output_format(settings.format);
    
    // Configure the filters in Rust
    if (given >> SET_LEVELS & 1) set_filter(settings.level_mask, 1);
    if (given & (1 << SET_AFTER | 1 << SET_BEFORE)) set_time_filter(settings.after, settings.before, 1);
    if (settings.pattern[0]) set_message_filter(settings.pattern, (int)strlen(settings.pattern));
    
    // Allocate the read buffers (before any output file is created)
    int num_items = 2 * num_threads + 2;
    for (int i = 0; i < num_items; i++) {
        item_pool[i].buffer = malloc(CHUNK_SIZE);
        if (!item_pool[i].buffer) { print_err("Error: out of memory\n"); return 1; }
        item_pool[i].next = free_items;
        free_items = &item_pool[i];
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
    size_t total_read = 0;
    
    // Start worker threads. They inherit a mask that blocks SIGINT and
    // SIGTERM, so these always arrive on this thread: in follow mode they
    // have to interrupt its read() or its sleep.
    sigset_t stop_signals;
    sigemptyset(&stop_signals);
    sigaddset(&stop_signals, SIGINT);
    sigaddset(&stop_signals, SIGTERM);
    pthread_sigmask(SIG_BLOCK, &stop_signals, NULL);
    pthread_t threads[MAX_THREADS];
    for (int i = 0; i < num_threads; i++) {
        if (pthread_create(&threads[i], NULL, worker_thread, &bucket_tables[i]) != 0) {
            print_err("Error: cannot create worker thread\n");
            return 1;
        }
    }
    
    // Follow mode: SIGINT and SIGTERM end the reading instead of the process,
    // so that the results are printed. That holds from the first input on,
    // not only once the last one is being followed.
    if (follow_mode) {
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = request_stop;
        sa.sa_flags = SA_RESETHAND;  // A second signal ends the process as usual
        sigemptyset(&sa.sa_mask);
        sigaction(SIGINT, &sa, NULL);
        sigaction(SIGTERM, &sa, NULL);
    }
    pthread_sigmask(SIG_UNBLOCK, &stop_signals, NULL);
    
    // Process each file (or stdin if no files)
    int input_failed = 0;  // An input could not be opened or read: exit status 1
    int file_count = (num_files == 0) ? 1 : num_files;
    for (int file_idx = 0; file_idx < file_count && !stop_requested; file_idx++) {
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
                input_failed = 1;
                continue;
            }
            // The size is only for the message below: pipes, FIFOs and
            // growing files are read until EOF whatever it says
            struct stat st;
            if (fstat(fd, &st) == 0 && st.st_size > 0) file_size = st.st_size;
            
            if (num_files > 1) {
                print_err("["); print_num(file_idx + 1); print_err("/"); print_num(num_files); print_err("] ");
            }
            print_err("Processing "); print_err(filepath); print_err(" (");
            print_num(file_size / (1024*1024)); print_err(" MB)...\n");
        }
        
        // Only the last file is followed
        int following = follow_mode && file_idx == file_count - 1;
        int tailing = 0;  // Following, and past what the file held at first
        
        // Read until EOF. Whole lines are queued after every read(), so data
        // arriving slowly on a pipe is never held back; the unfinished last
        // line moves to the front of the next buffer.
        WorkItem* item = get_item();
        size_t fill = 0;    // Bytes in item->buffer, which always starts at a line start
        int skip_line = 0;  // Dropping the rest of a line longer than a buffer
        
        while (!stop_requested) {
            ssize_t n = read(fd, item->buffer + fill, CHUNK_SIZE - fill);
            if (n < 0 && errno == EINTR) continue;
            if (n < 0 && errno == EAGAIN) {
                // Non-blocking descriptor (inherited pipe or tty): wait for data
                struct pollfd pfd = {fd, POLLIN, 0};
                poll(&pfd, 1, -1);
                continue;
            }
            if (n < 0) {
                print_err("Warning: cannot read "); print_err(from_stdin ? "stdin" : filepath); print_err("\n");
                input_failed = 1;
                break;
            }
            if (n == 0) {
                if (!following) break;
                // Follow mode: poll for appended data. The unfinished last
                // line stays in the buffer until its newline arrives.
                if (!tailing) {
                    tailing = 1;
                    finish_batch();
                    print_err("Following "); print_err(filepath); print_err(" (Ctrl+C to stop)...\n");
                }
                usleep(100000);  // 100ms poll interval
                continue;
            }
            
            total_read += n;
            char* buffer = item->buffer;
            size_t buf_size = fill + n;
            
            if (skip_line) {
                // Still inside the long line (fill is 0 here)
                char* nl = memchr(buffer, '\n', buf_size);
                if (!nl) continue;
                skip_line = 0;
                buf_size -= (size_t)(nl + 1 - buffer);
                memmove(buffer, nl + 1, buf_size);
            }
            
            // Only the new bytes can hold a newline
            size_t last_nl = buf_size;
            while (last_nl > fill && buffer[last_nl - 1] != '\n') last_nl--;
            
            if (last_nl == fill) {
                fill = buf_size;
                if (fill < CHUNK_SIZE) continue;
                // A line longer than a whole buffer: the parser only looks at
                // its head, so process that and drop the rest of the line
                last_nl = fill;
                skip_line = 1;
            }
            
            WorkItem* next = get_item();
            fill = buf_size - last_nl;
            memcpy(next->buffer, buffer + last_nl, fill);
            submit_item(item, last_nl);
            item = next;
            if (tailing) finish_batch();
        }
        
        // The final line of this input may lack its newline. In a followed
        // file such a line is still being written and is left out, and so is
        // what a stop signal cut off in the middle of an earlier input.
        if (fill > 0 && !following && !stop_requested) {
            submit_item(item, fill);
            item = NULL;
        }
        
        if (item) {
            pthread_mutex_lock(&queue_lock);
            release_item(item);
            pthread_mutex_unlock(&queue_lock);
        }
        if (!from_stdin) close(fd);
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
    
    // Write the format trailer and flush. Only when records were being
    // written: --count-only and --stats must leave stdout empty.
    if (!count_only && stats_mode == 0) {
        finish_output();
    }
    
    for (int i = 0; i < num_items; i++) free(item_pool[i].buffer);
    
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
    print_err("Matched: "); print_num(global_stats.matched); print_err("\n");
    print_err("--- By Level ---\n");
    print_err("DEBUG:   "); print_num(global_stats.levels[0]); print_err("\n");
    print_err("INFO:    "); print_num(global_stats.levels[1]); print_err("\n");
    print_err("WARN:    "); print_num(global_stats.levels[2]); print_err("\n");
    print_err("ERROR:   "); print_num(global_stats.levels[3]); print_err("\n");
    
    // Print time-based stats if in stats mode
    if (stats_mode > 0) {
        const char* mode_names[] = {"", "Hourly", "Daily", "Minute", "By Level"};
        print_err("--- Aggregation ("); 
        print_err(mode_names[stats_mode]); 
        print_err(") ---\n");
        
        BucketRun runs[MAX_THREADS];
        int num_runs = collect_runs(runs);
        
        if (stats_mode == 4) {
            // By-level mode: the single bucket holds every matched entry (it
            // is missing when nothing matched), levels in fixed order
            const char* level_names[] = {"DEBUG", "INFO", "WARN", "ERROR"};
            BlockSum sum = {0};
            next_block(runs, &num_runs, &sum);
            for (int i = 0; i < 4; i++) {
                char line[64];
                snprintf(line, sizeof(line), "%-6s: %llu\n", level_names[i], sum.counts[0][i] + sum.carried[0][i]);
                print_err(line);
            }
        } else {
            print_buckets(runs, num_runs);
        }
        
        for (int i = 0; i < num_threads; i++) {
            for (size_t j = 0; j < bucket_tables[i].count; j++) free(bucket_tables[i].slots[j].block->carried);
            for (int seg = 0; seg < bucket_tables[i].num_segments; seg++) free(bucket_tables[i].segments[seg]);
            free(bucket_tables[i].slots);
        }
    }
    
    print_err("--- Performance ---\n");
    
    // Calculate and print performance stats. The time runs up to here: the
    // last flush and the merge of the aggregation are part of the work.
    double end_time = get_time();
    double elapsed = end_time - start_time;
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
    
    // Records that could not be written are a failure too
    return input_failed || output_failed();
}
