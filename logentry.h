#ifndef LOGENTRY_H
#define LOGENTRY_H

// Shared structure for cross-language communication (C ABI)
// Used by: C (reader), Zig (parser), Rust (processor), C++ (formatter)

struct LogEntry {
    int level;          // 0=DEBUG, 1=INFO, 2=WARN, 3=ERROR, -1=invalid
    int valid;          // 1=valid log entry, 0=invalid
    int filtered;       // 1=should output, 0=filtered out (set by processor)
    int msg_len;        // Length of extracted message
    long long timestamp; // Unix timestamp (seconds since epoch)
    char msg[256];      // Extracted message content
};

// parser.zig and processor.rs declare this layout by hand; fail the build if
// the C/C++ side ever stops matching it
#ifdef __cplusplus
static_assert(sizeof(struct LogEntry) == 280, "LogEntry must be 280 bytes");
#else
_Static_assert(sizeof(struct LogEntry) == 280, "LogEntry must be 280 bytes");
#endif

#endif
