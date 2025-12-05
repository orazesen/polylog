// processor.rs - Log processing and filtering (Rust component)
// Called from C after parsing, performs filtering and additional processing

#[repr(C)]
pub struct LogEntry {
    pub level: i32,
    pub valid: i32,
    pub filtered: i32, // 1=should output, 0=filtered out
    pub msg_len: i32,
    pub msg: [u8; 256],
}

#[repr(C)]
pub struct FilterConfig {
    pub level_mask: i32,    // Bitmask: bit0=DEBUG, bit1=INFO, bit2=WARN, bit3=ERROR
    pub filter_active: i32, // 1=filtering enabled, 0=pass all
}

// Global filter config (set by C reader)
static mut FILTER: FilterConfig = FilterConfig {
    level_mask: 0b1111, // All levels enabled by default
    filter_active: 0,
};

// Initialize filter from C
#[no_mangle]
pub unsafe extern "C" fn set_filter(level_mask: i32, active: i32) {
    FILTER.level_mask = level_mask;
    FILTER.filter_active = active;
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
    if FILTER.filter_active != 0 {
        let level_bit = 1 << e.level;
        if (FILTER.level_mask & level_bit) == 0 {
            e.filtered = 0; // Filtered out
            return;
        }
    }

    // Passed all filters
    e.filtered = 1;
}
