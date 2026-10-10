// parser.zig - Log validation and parsing (Zig component)
// Called from C, validates log format and extracts level
// Format: "YYYY-MM-DD HH:MM:SS LEVEL message"

pub const LogEntry = extern struct {
    level: c_int,
    valid: c_int,
    filtered: c_int,  // Set by processor
    msg_len: c_int,
    timestamp: c_longlong, // Unix timestamp
    msg: [256]u8,
};

// The layout is shared with C, C++ and Rust (logentry.h)
comptime {
    if (@sizeOf(LogEntry) != 280 or
        @offsetOf(LogEntry, "level") != 0 or @offsetOf(LogEntry, "valid") != 4 or
        @offsetOf(LogEntry, "filtered") != 8 or @offsetOf(LogEntry, "msg_len") != 12 or
        @offsetOf(LogEntry, "timestamp") != 16 or @offsetOf(LogEntry, "msg") != 24)
    {
        @compileError("LogEntry layout does not match logentry.h");
    }
}

// Unaligned loads in native byte order; the constants compared against them
// are built the same way, so nothing here depends on endianness
inline fn load32(ptr: [*]const u8) u32 {
    return @bitCast(ptr[0..4].*);
}

inline fn load64(ptr: [*]const u8) u64 {
    return @bitCast(ptr[0..8].*);
}

// Eight bytes of the timestamp shape: 'd' is a digit, '?' is not checked,
// anything else must match exactly
const Shape = struct { pat: u64, add: u64, mask: u64 };

fn shape(comptime tmpl: *const [8]u8) Shape {
    var pat: [8]u8 = undefined;
    var add: [8]u8 = undefined;
    var mask: [8]u8 = undefined;
    for (tmpl, 0..) |c, i| {
        const digit = c == 'd';
        const skip = c == '?';
        pat[i] = if (digit) '0' else if (skip) 0 else c;
        add[i] = if (digit) 6 else 0;
        mask[i] = if (digit) 0xF0 else if (skip) 0 else 0xFF;
    }
    return .{ .pat = @bitCast(pat), .add = @bitCast(add), .mask = @bitCast(mask) };
}

// Nonzero if any byte breaks the shape. x = byte ^ pat is 0..9 for a digit,
// so neither x nor x + 6 reaches the high nibble; other bytes need x == 0.
// A byte can only carry into its neighbour when it already fails itself.
inline fn mismatch(ptr: [*]const u8, comptime s: Shape) u64 {
    const x = load64(ptr) ^ s.pat;
    return (x | (x +% s.add)) & s.mask;
}

// Fast integer parsing (2 or 4 digits), only for bytes already known to be digits
inline fn parse2(ptr: [*]const u8) i32 {
    return (@as(i32, ptr[0] - '0') * 10) + @as(i32, ptr[1] - '0');
}

inline fn parse4(ptr: [*]const u8) i32 {
    return (@as(i32, ptr[0] - '0') * 1000) + (@as(i32, ptr[1] - '0') * 100) +
           (@as(i32, ptr[2] - '0') * 10) + @as(i32, ptr[3] - '0');
}

// Days per month in a non-leap year (index 0 unused)
const month_days = [13]u8{ 0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

inline fn is_leap(year: i32) bool {
    return @rem(year, 4) == 0 and (@rem(year, 100) != 0 or @rem(year, 400) == 0);
}

// Convert date/time to unix timestamp (simplified, assumes UTC)
inline fn to_timestamp(year: i32, month: i32, day: i32, hour: i32, min: i32, sec: i32) c_longlong {
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

// Level tokens. The lookup is keyed on two bits of the second letter
// (E, N, A, R all differ there) so that picking the candidate needs no branches.
const Level = struct {
    head: u32, // first four letters
    last: u8, // last letter (the fifth one for DEBUG and ERROR)
    end: u8, // offset just past the token
    level: c_int,
};

inline fn level_slot(second: u8) usize {
    return (second >> 1) & 3;
}

const level_table = blk: {
    const names = [4][]const u8{ "DEBUG", "INFO", "WARN", "ERROR" };
    var table: [4]Level = undefined;
    var used = [4]bool{ false, false, false, false };
    for (names, 0..) |name, i| {
        const slot = level_slot(name[1]);
        if (used[slot]) @compileError("level names collide in level_slot");
        used[slot] = true;
        table[slot] = .{
            .head = @bitCast(name[0..4].*),
            .last = name[name.len - 1],
            .end = 20 + name.len,
            .level = i,
        };
    }
    break :blk table;
};

// Export for C linkage
pub export fn parse_log(line: [*]const u8, len: c_int, entry: *LogEntry) void {
    // Initialize as invalid
    entry.valid = 0;
    entry.filtered = 0;
    entry.level = -1;
    entry.msg_len = 0;
    entry.timestamp = 0;
    entry.msg[0] = 0;

    if (len <= 0) return;
    var length: usize = @intCast(len);

    // CRLF input: drop one trailing carriage return
    if (line[length - 1] == '\r') length -= 1;

    // Must have at least "YYYY-MM-DD HH:MM:SS LEVE" (24 chars), which also
    // keeps the fixed-offset loads below inside the line
    if (length < 24) return;

    // Digits and separators of the timestamp (bytes 20..23 belong to the level)
    if ((mismatch(line, shape("dddd-dd-")) | mismatch(line + 8, shape("dd dd:dd")) |
        mismatch(line + 16, shape(":dd ????"))) != 0)
    {
        return;
    }

    // Level detection at position 20
    const lv = &level_table[level_slot(line[21])];
    const level_end: usize = lv.end;
    if (length < level_end) return;
    if (load32(line + 20) != lv.head or line[level_end - 1] != lv.last) return;

    // The level ends the line or is followed by one space, then the message
    var msg_start = level_end;
    if (length > level_end) {
        if (line[level_end] != ' ') return;
        msg_start += 1;
    }

    // Parse timestamp: YYYY-MM-DD HH:MM:SS
    const year = parse4(line);
    const month = parse2(line + 5);
    const day = parse2(line + 8);
    const hour = parse2(line + 11);
    const min = parse2(line + 14);
    const sec = parse2(line + 17);

    if (month < 1 or month > 12) return;
    const days_in_month = @as(i32, month_days[@intCast(month)]) + @intFromBool(month == 2 and is_leap(year));
    if (day < 1 or day > days_in_month or hour > 23 or min > 59 or sec > 59) return;

    entry.level = lv.level;
    entry.valid = 1;
    entry.timestamp = to_timestamp(year, month, day, hour, min, sec);

    // Extract message (possibly empty), truncated and NUL terminated.
    // Copied as 16-byte blocks, the last one ending exactly at the last byte:
    // for typical message lengths this is far cheaper than calling memcpy.
    const copy_len: usize = @min(length - msg_start, 255);
    const src = line + msg_start;
    var i: usize = 0;
    if (copy_len >= 16) {
        while (i + 16 < copy_len) : (i += 16) {
            entry.msg[i..][0..16].* = src[i..][0..16].*;
        }
        entry.msg[copy_len - 16 ..][0..16].* = src[copy_len - 16 ..][0..16].*;
    } else {
        while (i < copy_len) : (i += 1) {
            entry.msg[i] = src[i];
        }
    }
    entry.msg[copy_len] = 0;
    entry.msg_len = @intCast(copy_len);
}
