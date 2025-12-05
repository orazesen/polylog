#ifndef LOGENTRY_H
#define LOGENTRY_H

// Shared structure for cross-language communication (C ABI)
// Used by: C (reader), Zig (parser), Rust (processor), C++ (formatter)

struct LogEntry {
    int level;          // 0=DEBUG, 1=INFO, 2=WARN, 3=ERROR, -1=invalid
    int valid;          // 1=valid log entry, 0=invalid
    int filtered;       // 1=should output, 0=filtered out (set by processor)
    int msg_len;        // Length of extracted message
    char msg[256];      // Extracted message content
};

// Filter configuration (set by reader, used by processor)
struct FilterConfig {
    int level_mask;     // Bitmask: bit0=DEBUG, bit1=INFO, bit2=WARN, bit3=ERROR
    int filter_active;  // 1=filtering enabled, 0=pass all
};

#endif
