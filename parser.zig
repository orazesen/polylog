// parser.zig - Log validation and parsing (Zig component)
// Called from C, validates log format and extracts level
// Format: "YYYY-MM-DD HH:MM:SS LEVEL message"

const LogEntry = extern struct {
    level: c_int,
    valid: c_int,
    filtered: c_int,  // Set by processor
    msg_len: c_int,
    timestamp: c_longlong, // Unix timestamp
    msg: [256]u8,
};

// Fast integer parsing (2 or 4 digits)
fn parse2(ptr: [*]const u8) i32 {
    return (@as(i32, ptr[0] - '0') * 10) + @as(i32, ptr[1] - '0');
}

fn parse4(ptr: [*]const u8) i32 {
    return (@as(i32, ptr[0] - '0') * 1000) + (@as(i32, ptr[1] - '0') * 100) +
           (@as(i32, ptr[2] - '0') * 10) + @as(i32, ptr[3] - '0');
}

// Convert date/time to unix timestamp (simplified, assumes UTC)
fn to_timestamp(year: i32, month: i32, day: i32, hour: i32, min: i32, sec: i32) c_longlong {
    // Days since epoch (1970-01-01)
    var y = year;
    var m = month;
    if (m <= 2) {
        y -= 1;
        m += 12;
    }
    const era: i64 = @divFloor(@as(i64, y), 400);
    const yoe: i64 = @as(i64, y) - era * 400;
    const doy: i64 = @divFloor((153 * @as(i64, m - 3) + 2), 5) + @as(i64, day) - 1;
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days: i64 = era * 146097 + doe - 719468;
    return days * 86400 + @as(i64, hour) * 3600 + @as(i64, min) * 60 + @as(i64, sec);
}

// Export for C linkage
export fn parse_log(line: [*]const u8, len: c_int, entry: *LogEntry) void {
    const length: usize = @intCast(len);
    
    // Initialize as invalid
    entry.valid = 0;
    entry.filtered = 0;
    entry.level = -1;
    entry.msg_len = 0;
    entry.timestamp = 0;
    
    // Must have at least "YYYY-MM-DD HH:MM:SS LEVEL" (26 chars)
    if (length < 26) return;
    
    // Quick separator check for timestamp format
    if (line[4] != '-' or line[7] != '-' or line[10] != ' ' or
        line[13] != ':' or line[16] != ':' or line[19] != ' ') {
        return;
    }
    
    // Level detection at position 20
    const lv = line + 20;
    var level: c_int = -1;
    var msg_start: usize = 0;
    
    if (lv[0] == 'D' and lv[1] == 'E' and lv[2] == 'B' and lv[3] == 'U' and lv[4] == 'G') {
        level = 0;
        msg_start = 26; // after "DEBUG "
    } else if (lv[0] == 'I' and lv[1] == 'N' and lv[2] == 'F' and lv[3] == 'O') {
        level = 1;
        msg_start = 25; // after "INFO "
    } else if (lv[0] == 'W' and lv[1] == 'A' and lv[2] == 'R' and lv[3] == 'N') {
        level = 2;
        msg_start = 25; // after "WARN "
    } else if (lv[0] == 'E' and lv[1] == 'R' and lv[2] == 'R' and lv[3] == 'O' and lv[4] == 'R') {
        level = 3;
        msg_start = 26; // after "ERROR "
    }
    
    if (level < 0) return;
    
    entry.level = level;
    entry.valid = 1;
    
    // Parse timestamp: YYYY-MM-DD HH:MM:SS
    const year = parse4(line);
    const month = parse2(line + 5);
    const day = parse2(line + 8);
    const hour = parse2(line + 11);
    const min = parse2(line + 14);
    const sec = parse2(line + 17);
    entry.timestamp = to_timestamp(year, month, day, hour, min, sec);
    
    // Extract message if present
    if (msg_start < length) {
        const msg_len = length - msg_start;
        const copy_len = if (msg_len > 255) 255 else msg_len;
        var i: usize = 0;
        while (i < copy_len) : (i += 1) {
            entry.msg[i] = line[msg_start + i];
        }
        entry.msg[copy_len] = 0;
        entry.msg_len = @intCast(copy_len);
    }
}
