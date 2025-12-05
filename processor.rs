// processor.rs - Log processing and filtering (Rust component)
// Called from C after parsing, performs filtering and additional processing

#[repr(C)]
pub struct LogEntry {
    pub level: i32,
    pub valid: i32,
    pub filtered: i32, // 1=should output, 0=filtered out
    pub msg_len: i32,
    pub timestamp: i64, // Unix timestamp
    pub msg: [u8; 256],
}

// Global filter config (set by C reader)
static mut LEVEL_MASK: i32 = 0b1111; // All levels
static mut LEVEL_FILTER_ACTIVE: i32 = 0;
static mut TIME_AFTER: i64 = 0; // 0 = no filter
static mut TIME_BEFORE: i64 = i64::MAX; // MAX = no filter
static mut TIME_FILTER_ACTIVE: i32 = 0;
static mut MSG_PATTERN: [u8; 256] = [0; 256];
static mut MSG_PATTERN_LEN: usize = 0;
static mut MSG_FILTER_ACTIVE: i32 = 0;

// Initialize level filter from C
#[no_mangle]
pub unsafe extern "C" fn set_filter(level_mask: i32, active: i32) {
    LEVEL_MASK = level_mask;
    LEVEL_FILTER_ACTIVE = active;
}

// Initialize time filter from C
#[no_mangle]
pub unsafe extern "C" fn set_time_filter(after: i64, before: i64, active: i32) {
    TIME_AFTER = after;
    TIME_BEFORE = before;
    TIME_FILTER_ACTIVE = active;
}

// Initialize message filter from C (substring match, case-insensitive)
#[no_mangle]
pub unsafe extern "C" fn set_message_filter(pattern: *const u8, len: i32) {
    MSG_PATTERN_LEN = len as usize;
    if MSG_PATTERN_LEN > 255 {
        MSG_PATTERN_LEN = 255;
    }
    for i in 0..MSG_PATTERN_LEN {
        // Convert to lowercase for case-insensitive match
        let c = *pattern.add(i);
        MSG_PATTERN[i] = if c >= b'A' && c <= b'Z' { c + 32 } else { c };
    }
    MSG_FILTER_ACTIVE = 1;
}

// Case-insensitive substring search (no bounds checks to avoid panic symbols)
unsafe fn contains_pattern(msg: *const u8, msg_len: usize) -> bool {
    if MSG_PATTERN_LEN == 0 || MSG_PATTERN_LEN > msg_len {
        return false;
    }
    let end = msg_len - MSG_PATTERN_LEN + 1;
    let mut i = 0usize;
    while i < end {
        let mut matched = true;
        let mut j = 0usize;
        while j < MSG_PATTERN_LEN {
            let c = *msg.add(i + j);
            let c_lower = if c >= b'A' && c <= b'Z' { c + 32 } else { c };
            if c_lower != *MSG_PATTERN.as_ptr().add(j) {
                matched = false;
                break;
            }
            j += 1;
        }
        if matched {
            return true;
        }
        i += 1;
    }
    false
}

// Process and filter log entry
#[no_mangle]
pub unsafe extern "C" fn process_log(entry: *mut LogEntry) {
    let e = &mut *entry;

    // Early return if invalid
    if e.valid == 0 {
        e.filtered = 0;
        return;
    }

    // Apply level filter
    if LEVEL_FILTER_ACTIVE != 0 {
        let level_bit = 1 << e.level;
        if (LEVEL_MASK & level_bit) == 0 {
            e.filtered = 0;
            return;
        }
    }

    // Apply time range filter
    if TIME_FILTER_ACTIVE != 0 {
        if e.timestamp < TIME_AFTER || e.timestamp > TIME_BEFORE {
            e.filtered = 0;
            return;
        }
    }

    // Apply message filter (case-insensitive substring)
    if MSG_FILTER_ACTIVE != 0 {
        if !contains_pattern(e.msg.as_ptr(), e.msg_len as usize) {
            e.filtered = 0;
            return;
        }
    }

    // Passed all filters
    e.filtered = 1;
}
