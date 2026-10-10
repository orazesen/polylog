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

// Layout must match struct LogEntry in logentry.h (compile-time only, no runtime code)
const _: () = assert!(core::mem::size_of::<LogEntry>() == 280);

// Global filter config (set by C reader)
// Written only before the worker threads start and read-only afterwards, so the
// unsynchronized reads are sound; accessed by value or raw pointer, never by reference.
static mut LEVEL_MASK: i32 = 0b1111; // All levels
static mut LEVEL_FILTER_ACTIVE: i32 = 0;
static mut TIME_AFTER: i64 = i64::MIN; // MIN = no filter (dates before 1970 are negative)
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
// An empty pattern (also a null pointer or a negative length) means no message filter
#[no_mangle]
pub unsafe extern "C" fn set_message_filter(pattern: *const u8, len: i32) {
    if pattern.is_null() || len <= 0 {
        MSG_PATTERN_LEN = 0;
        MSG_FILTER_ACTIVE = 0;
        return;
    }
    let pat_len = if len > 255 { 255 } else { len as usize };
    let dst = &raw mut MSG_PATTERN as *mut u8;
    for i in 0..pat_len {
        // Convert to lowercase for case-insensitive match
        let c = *pattern.add(i);
        *dst.add(i) = if c >= b'A' && c <= b'Z' { c + 32 } else { c };
    }
    MSG_PATTERN_LEN = pat_len;
    MSG_FILTER_ACTIVE = 1;
}

// Case-insensitive substring search (no bounds checks to avoid panic symbols)
unsafe fn contains_pattern(msg: *const u8, msg_len: usize) -> bool {
    let pat = &raw const MSG_PATTERN as *const u8;
    let pat_len = MSG_PATTERN_LEN;
    if pat_len > msg_len {
        return false;
    }
    let end = msg_len - pat_len + 1;
    let mut i = 0usize;
    while i < end {
        let mut matched = true;
        let mut j = 0usize;
        while j < pat_len {
            let c = *msg.add(i + j);
            let c_lower = if c >= b'A' && c <= b'Z' { c + 32 } else { c };
            if c_lower != *pat.add(j) {
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
        // A level outside 0..=3 has no mask bit and must never become a shift amount
        if e.level < 0 || e.level > 3 || (LEVEL_MASK & (1 << e.level)) == 0 {
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
        // msg_len comes from the caller: keep the search inside msg
        let msg_len = (e.msg_len.max(0) as usize).min(e.msg.len());
        if !contains_pattern(e.msg.as_ptr(), msg_len) {
            e.filtered = 0;
            return;
        }
    }

    // Passed all filters
    e.filtered = 1;
}
