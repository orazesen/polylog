// test_logproc.zig - Unit tests for the Zig parser (parser.zig)
// Run with: make unit-test
// (The bare 'zig test test_logproc.zig' lacks the flags the Makefile adds: a
// -target on macOS, and --cache-dir ./.zig-cache, without which zig may reuse
// a test binary that another checkout built from its own parser.zig.)
// Every test calls the real parse_log, the function the C reader links against

const std = @import("std");
const testing = std.testing;
const parser = @import("parser.zig");
const LogEntry = parser.LogEntry;

const DEBUG = 0;
const INFO = 1;
const WARN = 2;
const ERROR = 3;
const level_names = [_][]const u8{ "DEBUG", "INFO", "WARN", "ERROR" };

// 2025-01-01 00:00:00 UTC
const T2025: i64 = 1735689600;

// ============================================================================
// Helpers
// ============================================================================

// Two pages, the second one inaccessible. Every input is copied so that it
// ends exactly at the boundary: a read of line[len] or beyond crashes the test
// run instead of passing unnoticed.
var guard_end: ?[*]u8 = null;

fn guardEnd() [*]u8 {
    if (guard_end) |end| return end;
    const page = std.heap.pageSize();
    const prot = std.posix.PROT;
    const map = std.posix.mmap(null, 2 * page, prot.READ | prot.WRITE, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0) catch @panic("mmap failed");
    std.posix.mprotect(@alignCast(map[page..]), prot.NONE) catch @panic("mprotect failed");
    guard_end = map.ptr + page;
    return guard_end.?;
}

// The entry starts out as garbage, so a field parse_log leaves unset is noticed
fn parseRaw(ptr: [*]const u8, len: c_int) LogEntry {
    var entry: LogEntry = undefined;
    @memset(std.mem.asBytes(&entry), 0xAA);
    parser.parse_log(ptr, len, &entry);
    return entry;
}

fn parse(line: []const u8) LogEntry {
    std.debug.assert(line.len <= 4096);
    const start = guardEnd() - line.len;
    @memcpy(start[0..line.len], line);
    return parseRaw(start, @intCast(line.len));
}

fn printInput(line: []const u8) void {
    std.debug.print("\ninput: \"{f}\"\n", .{std.zig.fmtString(line)});
}

// The state of an entry after invalid input
fn expectReset(entry: LogEntry) !void {
    try testing.expectEqual(0, entry.valid);
    try testing.expectEqual(-1, entry.level);
    try testing.expectEqual(0, entry.filtered);
    try testing.expectEqual(0, entry.msg_len);
    try testing.expectEqual(0, entry.timestamp);
    try testing.expectEqual(0, entry.msg[0]);
}

fn expectInvalid(line: []const u8) !void {
    errdefer printInput(line);
    try expectReset(parse(line));
}

fn expectValid(line: []const u8, level: c_int, timestamp: i64, msg: []const u8) !void {
    errdefer printInput(line);
    const entry = parse(line);
    try testing.expectEqual(1, entry.valid);
    try testing.expectEqual(level, entry.level);
    try testing.expectEqual(0, entry.filtered); // left for the processor
    try testing.expectEqual(timestamp, entry.timestamp);
    try testing.expectEqual(@as(c_int, @intCast(msg.len)), entry.msg_len);
    try testing.expectEqualSlices(u8, msg, entry.msg[0..msg.len]);
    try testing.expectEqual(0, entry.msg[msg.len]);
}

// Independent calendar rules for the sweeps below
fn isLeap(year: u32) bool {
    return (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
}

fn daysInMonth(year: u32, month: u32) u32 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeap(year)) 29 else 28,
        else => 0,
    };
}

// ============================================================================
// TEST SUITE: Struct Layout
// ============================================================================

test "LogEntry layout matches logentry.h" {
    try testing.expectEqual(280, @sizeOf(LogEntry));
    try testing.expectEqual(0, @offsetOf(LogEntry, "level"));
    try testing.expectEqual(4, @offsetOf(LogEntry, "valid"));
    try testing.expectEqual(8, @offsetOf(LogEntry, "filtered"));
    try testing.expectEqual(12, @offsetOf(LogEntry, "msg_len"));
    try testing.expectEqual(16, @offsetOf(LogEntry, "timestamp"));
    try testing.expectEqual(24, @offsetOf(LogEntry, "msg"));
}

// ============================================================================
// TEST SUITE: Basic Parsing
// ============================================================================

test "parse each level" {
    try expectValid("2025-01-15 10:30:45 DEBUG User logged in successfully", DEBUG, 1736937045, "User logged in successfully");
    try expectValid("2025-06-20 14:22:33 INFO Application started", INFO, 1750429353, "Application started");
    try expectValid("2025-03-10 08:15:00 WARN Memory usage high", WARN, 1741594500, "Memory usage high");
    try expectValid("2025-12-31 23:59:59 ERROR Connection failed", ERROR, 1767225599, "Connection failed");
}

test "process multiple log lines" {
    const lines = [_][]const u8{
        "2025-01-01 10:00:00 DEBUG First",
        "2025-01-01 10:00:01 INFO Second",
        "this is not a valid log",
        "2025-01-01 10:00:02 WARN Third",
        "random garbage 12345",
        "2025-01-01 10:00:03 ERROR Fourth",
        "missing timestamp",
        "2025-01-01 10:00:04 INFO Fifth",
    };

    var valid_count: usize = 0;
    var level_counts = [_]usize{ 0, 0, 0, 0 };
    var last_timestamp: i64 = 0;
    for (lines) |line| {
        const entry = parse(line);
        if (entry.valid == 1) {
            valid_count += 1;
            level_counts[@intCast(entry.level)] += 1;
            try testing.expect(entry.timestamp > last_timestamp);
            last_timestamp = entry.timestamp;
        }
    }

    try testing.expectEqual(5, valid_count);
    try testing.expectEqualSlices(usize, &.{ 1, 2, 1, 1 }, &level_counts);
}

// ============================================================================
// TEST SUITE: Timestamps
// ============================================================================

test "known timestamps" {
    try expectValid("1970-01-01 00:00:00 INFO epoch", INFO, 0, "epoch");
    try expectValid("2025-01-01 00:00:00 INFO new year", INFO, 1735689600, "new year");
    try expectValid("2025-01-01 12:30:45 INFO x", INFO, 1735734645, "x");
    try expectValid("2025-06-15 23:59:59 INFO x", INFO, 1750031999, "x");
    try expectValid("2038-01-19 03:14:08 INFO past 32 bits", INFO, 2147483648, "past 32 bits");
    try expectValid("9999-12-31 23:59:59 INFO x", INFO, 253402300799, "x");
}

test "timestamps before 1970 are negative" {
    try expectValid("1969-12-31 23:59:59 INFO x", INFO, -1, "x");
    try expectValid("1969-07-20 20:17:40 INFO x", INFO, -14182940, "x");
    try expectValid("1900-01-01 00:00:00 INFO x", INFO, -2208988800, "x");
    try expectValid("0001-01-01 00:00:00 INFO x", INFO, -62135596800, "x");
    try expectValid("0000-01-01 00:00:00 INFO x", INFO, -62167219200, "x");
}

test "leap days" {
    try expectValid("2024-02-29 12:00:00 INFO leap day", INFO, 1709208000, "leap day");
    try expectValid("2000-02-29 23:59:59 INFO x", INFO, 951868799, "x"); // divisible by 400
    try expectValid("1600-02-29 00:00:00 INFO x", INFO, -11670998400, "x");
    try expectValid("2400-02-29 00:00:00 INFO x", INFO, 13574563200, "x");
    try expectValid("0000-02-29 00:00:00 INFO x", INFO, -62162121600, "x");

    try expectInvalid("2025-02-29 00:00:00 INFO x");
    try expectInvalid("2023-02-29 00:00:00 INFO x");
    try expectInvalid("1900-02-29 00:00:00 INFO x"); // divisible by 100 only
    try expectInvalid("2100-02-29 00:00:00 INFO x");
    try expectInvalid("2024-02-30 00:00:00 INFO x");
    try expectInvalid("2025-02-30 00:00:00 INFO x");
}

test "calendar sweep: months 00-13 and days 00-32 of every year from 1599 to 2401" {
    var buf: [64]u8 = undefined;
    var day_number: i64 = -135505; // 1599-01-01 counted from 1970-01-01
    var year: u32 = 1599;
    while (year <= 2401) : (year += 1) {
        var month: u32 = 0;
        while (month <= 13) : (month += 1) {
            var day: u32 = 0;
            while (day <= 32) : (day += 1) {
                const line = try std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2} 00:00:00 WARN x", .{ year, month, day });
                if (day >= 1 and day <= daysInMonth(year, month)) {
                    if (year == 1970 and month == 1 and day == 1) try testing.expectEqual(0, day_number);
                    try expectValid(line, WARN, day_number * 86400, "x");
                    day_number += 1;
                } else {
                    try expectInvalid(line);
                }
            }
        }
    }
    try testing.expectEqual(157785, day_number); // 2402-01-01
}

test "every four-digit year is accepted" {
    var buf: [64]u8 = undefined;
    var day_number: i64 = -719528; // 0000-01-01 counted from 1970-01-01
    var year: u32 = 0;
    while (year <= 9999) : (year += 1) {
        const leap: i64 = @intFromBool(isLeap(year));

        var line = try std.fmt.bufPrint(&buf, "{d:0>4}-01-01 00:00:00 DEBUG x", .{year});
        try expectValid(line, DEBUG, day_number * 86400, "x");

        line = try std.fmt.bufPrint(&buf, "{d:0>4}-02-29 00:00:00 DEBUG x", .{year});
        if (leap == 1) try expectValid(line, DEBUG, (day_number + 59) * 86400, "x") else try expectInvalid(line);

        line = try std.fmt.bufPrint(&buf, "{d:0>4}-12-31 23:59:59 DEBUG x", .{year});
        try expectValid(line, DEBUG, (day_number + 364 + leap) * 86400 + 86399, "x");

        day_number += 365 + leap;
    }
    try testing.expectEqual(2932897, day_number); // 10000-01-01
}

test "time of day sweep: hours, minutes and seconds 00-99" {
    var buf: [64]u8 = undefined;
    var v: u32 = 0;
    while (v <= 99) : (v += 1) {
        var line = try std.fmt.bufPrint(&buf, "2025-01-01 {d:0>2}:00:00 ERROR x", .{v});
        if (v <= 23) try expectValid(line, ERROR, T2025 + v * 3600, "x") else try expectInvalid(line);

        line = try std.fmt.bufPrint(&buf, "2025-01-01 00:{d:0>2}:00 ERROR x", .{v});
        if (v <= 59) try expectValid(line, ERROR, T2025 + v * 60, "x") else try expectInvalid(line);

        line = try std.fmt.bufPrint(&buf, "2025-01-01 00:00:{d:0>2} ERROR x", .{v});
        if (v <= 59) try expectValid(line, ERROR, T2025 + v, "x") else try expectInvalid(line);
    }
}

// ============================================================================
// TEST SUITE: Invalid Timestamps
// ============================================================================

const sample = "2025-01-15 10:30:45 INFO User logged in";
const digit_positions = [_]usize{ 0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18 };
const separator_positions = [_]usize{ 4, 7, 10, 13, 16, 19 };

test "reject a non-digit in each of the 14 digit positions" {
    try expectValid(sample, INFO, 1736937045, "User logged in");
    for (digit_positions) |pos| {
        // every byte value, including the ones below '0'
        var c: usize = 0;
        while (c <= 255) : (c += 1) {
            if (c >= '0' and c <= '9') continue;
            var line = sample.*;
            line[pos] = @intCast(c);
            try expectInvalid(&line);
        }
    }
}

test "reject a wrong byte in each separator position" {
    for (separator_positions) |pos| {
        var c: usize = 0;
        while (c <= 255) : (c += 1) {
            if (c == sample[pos]) continue;
            var line = sample.*;
            line[pos] = @intCast(c);
            try expectInvalid(&line);
        }
    }
}

test "reject out-of-range month and day" {
    try expectInvalid("2025-00-10 10:30:45 INFO Test");
    try expectInvalid("2025-13-10 10:30:45 INFO Test");
    try expectInvalid("2025-01-00 10:30:45 INFO Test");
    try expectInvalid("2025-01-32 10:30:45 INFO Test");

    // the 31st only exists in seven months
    try expectInvalid("2025-04-31 10:30:45 INFO Test");
    try expectInvalid("2025-06-31 10:30:45 INFO Test");
    try expectInvalid("2025-09-31 10:30:45 INFO Test");
    try expectInvalid("2025-11-31 10:30:45 INFO Test");
    try expectValid("2025-04-30 00:00:00 INFO Test", INFO, 1745971200, "Test");
    try expectValid("2025-12-31 00:00:00 INFO Test", INFO, 1767139200, "Test");
}

test "reject out-of-range hour, minute and second" {
    try expectInvalid("2025-01-01 24:00:00 INFO Test");
    try expectInvalid("2025-01-01 10:60:00 INFO Test");
    try expectInvalid("2025-01-01 10:30:60 INFO Test");
    try expectValid("2025-01-01 23:59:59 INFO Test", INFO, T2025 + 86399, "Test");
}

test "reject garbage that only has the separators right" {
    try expectInvalid("2025-13-45 25:61:61 INFO x");
    try expectInvalid("abcd-ef-gh ij:kl:mn ERROR x");
    try expectInvalid("    -  -     :  :   INFO x");
}

test "reject other line formats" {
    try expectInvalid("[2025-01-01 12:00:00] INFO Bracketed");
    try expectInvalid("2025/01/01 10:30:45 INFO Test");
    try expectInvalid("2025-01-01T10:30:45 INFO Test");
    try expectInvalid(" 2025-01-01 10:30:45 INFO Test");
    try expectInvalid("2025-01-01 10:30:45  INFO Test");
    try expectInvalid("2025-1-1 10:30:45 INFO Test padding");
    try expectInvalid("this is not a valid log");
    try expectInvalid("random garbage 12345");
    try expectInvalid("missing timestamp");
}

// ============================================================================
// TEST SUITE: Levels
// ============================================================================

test "reject unknown levels" {
    try expectInvalid("2025-01-01 10:30:45 TRACE Test");
    try expectInvalid("2025-01-01 10:30:45 FATAL Test");
    try expectInvalid("2025-01-01 10:30:45 NOTICE Test");
    try expectInvalid("2025-01-01 10:30:45 DEBU Test"); // right start, wrong fifth letter
    try expectInvalid("2025-01-01 10:30:45 ERRO Test");
    try expectInvalid("2025-01-01 10:30:45 12345 Test");
}

test "reject lowercase and mixed-case levels" {
    try expectInvalid("2025-01-01 10:30:45 debug Test");
    try expectInvalid("2025-01-01 10:30:45 info Test");
    try expectInvalid("2025-01-01 10:30:45 warn Test");
    try expectInvalid("2025-01-01 10:30:45 error Test");
    try expectInvalid("2025-01-01 10:30:45 Info Test");
    try expectInvalid("2025-01-01 10:30:45 ERROr Test");
}

test "reject a level without word boundary" {
    try expectInvalid("2025-01-01 10:30:45 DEBUGGING not a level");
    try expectInvalid("2025-01-01 10:30:45 INFOXhello");
    try expectInvalid("2025-01-01 10:30:45 INFOX");
    try expectInvalid("2025-01-01 10:30:45 INFORMATION overload");
    try expectInvalid("2025-01-01 10:30:45 WARNING disk full");
    try expectInvalid("2025-01-01 10:30:45 ERRORS found");
    try expectInvalid("2025-01-01 10:30:45 DEBUGX");
    try expectInvalid("2025-01-01 10:30:45 INFO\tTest"); // only a space separates
    try expectInvalid("2025-01-01 10:30:45 ERROR:Test");
    try expectInvalid("2025-01-01 10:30:45 WARN\x00");
}

test "reject any single wrong byte inside the level" {
    var buf: [64]u8 = undefined;
    for (level_names) |name| {
        const line = try std.fmt.bufPrint(&buf, "2025-01-01 00:00:00 {s} message", .{name});
        for (20..20 + name.len) |pos| {
            const original = line[pos];
            var c: usize = 0;
            while (c <= 255) : (c += 1) {
                if (c == original) continue;
                line[pos] = @intCast(c);
                try expectInvalid(line);
            }
            line[pos] = original;
        }
    }
}

// ============================================================================
// TEST SUITE: Message Extraction
// ============================================================================

test "empty message for every level, with and without the trailing space" {
    var buf: [64]u8 = undefined;
    for (level_names, 0..) |name, level| {
        var line = try std.fmt.bufPrint(&buf, "2025-01-01 00:00:00 {s}", .{name});
        try expectValid(line, @intCast(level), T2025, "");
        line = try std.fmt.bufPrint(&buf, "2025-01-01 00:00:00 {s} ", .{name});
        try expectValid(line, @intCast(level), T2025, "");
    }
}

test "message bytes are preserved exactly" {
    try expectValid("2025-01-01 00:00:00 INFO User john@example.com logged in from 192.168.1.1", INFO, T2025, "User john@example.com logged in from 192.168.1.1");
    try expectValid("2025-01-01 00:00:00 ERROR Failed after 3 retries: code=-1, msg='timeout'", ERROR, T2025, "Failed after 3 retries: code=-1, msg='timeout'");
    try expectValid("2025-01-01 00:00:00 INFO Message with \"quotes\" and \\backslash", INFO, T2025, "Message with \"quotes\" and \\backslash");
    try expectValid("2025-01-01 00:00:00 WARN Hello 世界 🌍", WARN, T2025, "Hello 世界 🌍");
    try expectValid("2025-01-01 00:00:00 DEBUG a\x00b\tc\xff\x80", DEBUG, T2025, "a\x00b\tc\xff\x80");
}

test "only the single space after the level is dropped" {
    try expectValid("2025-01-01 00:00:00 DEBUG   Padded message   ", DEBUG, T2025, "  Padded message   ");
    try expectValid("2025-01-01 00:00:00 INFO  x", INFO, T2025, " x");
    try expectValid("2025-01-01 00:00:00 WARN  ", WARN, T2025, " ");
    try expectValid("2025-01-01 00:00:00 ERROR INFO nested", ERROR, T2025, "INFO nested");
}

test "message of every length from 0 to 300 is copied and truncated at 255" {
    var line: [400]u8 = undefined;
    for (level_names, 0..) |name, level| {
        const prefix = try std.fmt.bufPrint(&line, "2025-01-01 00:00:00 {s} ", .{name});
        const msg = line[prefix.len..][0..300];
        for (msg, 0..) |*c, i| c.* = @intCast('!' + (i * 7) % 90);

        var n: usize = 0;
        while (n <= 300) : (n += 1) {
            const entry = parse(line[0 .. prefix.len + n]);
            const kept = @min(n, 255);
            try testing.expectEqual(1, entry.valid);
            try testing.expectEqual(@as(c_int, @intCast(level)), entry.level);
            try testing.expectEqual(@as(c_int, @intCast(kept)), entry.msg_len);
            try testing.expectEqualSlices(u8, msg[0..kept], entry.msg[0..kept]);
            try testing.expectEqual(0, entry.msg[kept]); // NUL terminator, at msg[255] at most
        }
    }
}

// ============================================================================
// TEST SUITE: CRLF Input
// ============================================================================

test "one trailing carriage return is stripped" {
    try expectValid("2025-01-01 00:00:00 INFO Windows line\r", INFO, T2025, "Windows line");
    try expectValid("2025-01-01 00:00:00 INFO\r", INFO, T2025, "");
    try expectValid("2025-01-01 00:00:00 ERROR \r", ERROR, T2025, "");
    try expectValid("2025-01-01 00:00:00 DEBUG\r", DEBUG, T2025, "");

    // only one, and only at the end
    try expectValid("2025-01-01 00:00:00 INFO two\r\r", INFO, T2025, "two\r");
    try expectValid("2025-01-01 00:00:00 INFO in\rside", INFO, T2025, "in\rside");

    try expectInvalid("\r");
    try expectInvalid("2025-01-01 00:00:00\r");
    try expectInvalid("2025-01-01 00:00:00 ERRO\r");
    try expectInvalid("2025-01-01 00:00:00 INFOX\r");
}

test "carriage return is stripped from the line before the message is truncated" {
    const prefix = "2025-01-01 00:00:00 INFO ";
    try expectValid(prefix ++ "A" ** 255 ++ "\r", INFO, T2025, "A" ** 255);
    // the second-to-last CR is message content and still fits
    try expectValid(prefix ++ "A" ** 254 ++ "\r\r", INFO, T2025, "A" ** 254 ++ "\r");
}

// ============================================================================
// TEST SUITE: Line Length
// ============================================================================

test "every prefix of a valid line, length 0 to 30" {
    var buf: [64]u8 = undefined;
    for (level_names, 0..) |name, level| {
        const line = try std.fmt.bufPrint(&buf, "2025-01-01 00:00:00 {s} abcdefghij", .{name});
        const level_end = 20 + name.len;
        var n: usize = 0;
        while (n <= 30) : (n += 1) {
            const prefix = line[0..n];
            if (n < level_end) {
                try expectInvalid(prefix);
            } else {
                const msg = if (n > level_end) prefix[level_end + 1 ..] else "";
                try expectValid(prefix, @intCast(level), T2025, msg);
            }
        }
    }
}

test "zero and negative len" {
    // nothing at this address is readable
    const unreadable = guardEnd();
    for ([_]c_int{ 0, -1, -26, std.math.minInt(c_int) }) |len| {
        try expectReset(parseRaw(unreadable, len));
    }

    const line = "2025-01-01 00:00:00 INFO x";
    try expectReset(parseRaw(line.ptr, 0));
    try expectReset(parseRaw(line.ptr, -@as(c_int, line.len)));
}

// ============================================================================
// TEST SUITE: Reset On Invalid Input
// ============================================================================

test "invalid input resets an entry that held a valid result" {
    var entry: LogEntry = undefined;
    const good = "2025-01-01 00:00:00 ERROR disk full";
    parser.parse_log(good.ptr, good.len, &entry);
    try testing.expectEqual(1, entry.valid);
    try testing.expectEqual(ERROR, entry.level);
    try testing.expectEqual(9, entry.msg_len);
    entry.filtered = 1; // as the processor would

    // rejected at the very last check, after the level was recognised
    const bad = "2025-01-01 00:00:60 ERROR disk full";
    parser.parse_log(bad.ptr, bad.len, &entry);
    try expectReset(entry);
}
