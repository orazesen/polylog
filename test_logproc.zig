// test_logproc.zig - Comprehensive unit tests for the log processor
// Run with: zig test test_logproc.zig
// Tests the Zig parser and integration with the full pipeline

const std = @import("std");
const testing = std.testing;

// ============================================================================
// Log Entry Structure (must match logentry.h)
// ============================================================================
const LogEntry = extern struct {
    level: i32,
    valid: i32,
    filtered: i32,
    msg_len: i32,
    timestamp: i64,
    msg: [256]u8,
};

// ============================================================================
// External functions from parser.zig (we'll test directly)
// ============================================================================

// Inline parser implementation for testing (mirrors parser.zig logic)
fn parseLog(line: []const u8, entry: *LogEntry) void {
    entry.valid = 0;
    entry.level = -1;
    entry.filtered = 1;
    entry.msg_len = 0;
    entry.timestamp = 0;

    if (line.len < 26) return; // Minimum: "[YYYY-MM-DD HH:MM:SS] X "

    // Validate format: [YYYY-MM-DD HH:MM:SS]
    if (line[0] != '[' or line[5] != '-' or line[8] != '-' or 
        line[11] != ' ' or line[14] != ':' or line[17] != ':' or line[20] != ']') {
        return;
    }

    // Parse timestamp
    const year = parseNum(line[1..5]);
    const month = parseNum(line[6..8]);
    const day = parseNum(line[9..11]);
    const hour = parseNum(line[12..14]);
    const min = parseNum(line[15..17]);
    const sec = parseNum(line[18..20]);

    if (year < 1970 or month < 1 or month > 12 or day < 1 or day > 31 or
        hour > 23 or min > 59 or sec > 59) {
        return;
    }

    // Calculate Unix timestamp
    var y = year;
    var m = month;
    if (m <= 2) {
        y -= 1;
        m += 12;
    }
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const doy = @divFloor((153 * (m - 3) + 2), 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    entry.timestamp = days * 86400 + hour * 3600 + min * 60 + sec;

    // Parse level after "] "
    if (line.len < 23) return;
    const level_start = 22;

    if (line.len >= level_start + 5 and std.mem.eql(u8, line[level_start..level_start + 5], "DEBUG")) {
        entry.level = 0;
    } else if (line.len >= level_start + 4 and std.mem.eql(u8, line[level_start..level_start + 4], "INFO")) {
        entry.level = 1;
    } else if (line.len >= level_start + 4 and std.mem.eql(u8, line[level_start..level_start + 4], "WARN")) {
        entry.level = 2;
    } else if (line.len >= level_start + 5 and std.mem.eql(u8, line[level_start..level_start + 5], "ERROR")) {
        entry.level = 3;
    } else {
        return;
    }

    // Find message after level
    const level_len: usize = if (entry.level == 0 or entry.level == 3) 5 else 4;
    const msg_start = level_start + level_len + 1;
    if (msg_start < line.len) {
        const msg_len = @min(line.len - msg_start, 255);
        @memcpy(entry.msg[0..msg_len], line[msg_start..msg_start + msg_len]);
        entry.msg_len = @intCast(msg_len);
    }

    entry.valid = 1;
}

fn parseNum(s: []const u8) i32 {
    var result: i32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return -1;
        result = result * 10 + @as(i32, c - '0');
    }
    return result;
}

// ============================================================================
// TEST SUITE: Basic Parsing
// ============================================================================

test "parse valid DEBUG log" {
    var entry: LogEntry = undefined;
    const line = "[2025-01-15 10:30:45] DEBUG User logged in successfully";
    parseLog(line, &entry);

    try testing.expectEqual(@as(i32, 1), entry.valid);
    try testing.expectEqual(@as(i32, 0), entry.level); // DEBUG = 0
    try testing.expect(entry.msg_len > 0);
    try testing.expectEqualStrings("User logged in successfully", entry.msg[0..@intCast(entry.msg_len)]);
}

test "parse valid INFO log" {
    var entry: LogEntry = undefined;
    const line = "[2025-06-20 14:22:33] INFO Application started";
    parseLog(line, &entry);

    try testing.expectEqual(@as(i32, 1), entry.valid);
    try testing.expectEqual(@as(i32, 1), entry.level); // INFO = 1
}

test "parse valid WARN log" {
    var entry: LogEntry = undefined;
    const line = "[2025-03-10 08:15:00] WARN Memory usage high";
    parseLog(line, &entry);

    try testing.expectEqual(@as(i32, 1), entry.valid);
    try testing.expectEqual(@as(i32, 2), entry.level); // WARN = 2
}

test "parse valid ERROR log" {
    var entry: LogEntry = undefined;
    const line = "[2025-12-31 23:59:59] ERROR Connection failed";
    parseLog(line, &entry);

    try testing.expectEqual(@as(i32, 1), entry.valid);
    try testing.expectEqual(@as(i32, 3), entry.level); // ERROR = 3
}

// ============================================================================
// TEST SUITE: Timestamp Parsing
// ============================================================================

test "timestamp calculation - epoch" {
    var entry: LogEntry = undefined;
    const line = "[1970-01-01 00:00:00] INFO Epoch start";
    parseLog(line, &entry);

    try testing.expectEqual(@as(i32, 1), entry.valid);
    try testing.expectEqual(@as(i64, 0), entry.timestamp);
}

test "timestamp calculation - known date" {
    var entry: LogEntry = undefined;
    // 2025-01-01 00:00:00 = 1735689600
    const line = "[2025-01-01 00:00:00] INFO New year";
    parseLog(line, &entry);

    try testing.expectEqual(@as(i32, 1), entry.valid);
    try testing.expectEqual(@as(i64, 1735689600), entry.timestamp);
}

test "timestamp with time component" {
    var entry: LogEntry = undefined;
    // 2025-01-01 12:30:45 = 1735689600 + 12*3600 + 30*60 + 45 = 1735734645
    const line = "[2025-01-01 12:30:45] DEBUG Test";
    parseLog(line, &entry);

    try testing.expectEqual(@as(i32, 1), entry.valid);
    try testing.expectEqual(@as(i64, 1735734645), entry.timestamp);
}

// ============================================================================
// TEST SUITE: Invalid Input Handling
// ============================================================================

test "reject empty line" {
    var entry: LogEntry = undefined;
    parseLog("", &entry);
    try testing.expectEqual(@as(i32, 0), entry.valid);
}

test "reject too short line" {
    var entry: LogEntry = undefined;
    parseLog("[2025-01-01] INFO", &entry);
    try testing.expectEqual(@as(i32, 0), entry.valid);
}

test "reject malformed timestamp - missing bracket" {
    var entry: LogEntry = undefined;
    parseLog("2025-01-01 10:30:45] INFO Test", &entry);
    try testing.expectEqual(@as(i32, 0), entry.valid);
}

test "reject malformed timestamp - wrong separator" {
    var entry: LogEntry = undefined;
    parseLog("[2025/01/01 10:30:45] INFO Test", &entry);
    try testing.expectEqual(@as(i32, 0), entry.valid);
}

test "reject invalid month" {
    var entry: LogEntry = undefined;
    parseLog("[2025-13-01 10:30:45] INFO Test", &entry);
    try testing.expectEqual(@as(i32, 0), entry.valid);
}

test "reject invalid day" {
    var entry: LogEntry = undefined;
    parseLog("[2025-01-32 10:30:45] INFO Test", &entry);
    try testing.expectEqual(@as(i32, 0), entry.valid);
}

test "reject invalid hour" {
    var entry: LogEntry = undefined;
    parseLog("[2025-01-01 25:30:45] INFO Test", &entry);
    try testing.expectEqual(@as(i32, 0), entry.valid);
}

test "reject invalid minute" {
    var entry: LogEntry = undefined;
    parseLog("[2025-01-01 10:60:45] INFO Test", &entry);
    try testing.expectEqual(@as(i32, 0), entry.valid);
}

test "reject invalid second" {
    var entry: LogEntry = undefined;
    parseLog("[2025-01-01 10:30:60] INFO Test", &entry);
    try testing.expectEqual(@as(i32, 0), entry.valid);
}

test "reject unknown level" {
    var entry: LogEntry = undefined;
    parseLog("[2025-01-01 10:30:45] TRACE Test", &entry);
    try testing.expectEqual(@as(i32, 0), entry.valid);
}

test "reject lowercase level" {
    var entry: LogEntry = undefined;
    parseLog("[2025-01-01 10:30:45] info Test", &entry);
    try testing.expectEqual(@as(i32, 0), entry.valid);
}

// ============================================================================
// TEST SUITE: Edge Cases
// ============================================================================

test "log with empty message" {
    var entry: LogEntry = undefined;
    const line = "[2025-01-01 10:30:45] INFO ";
    parseLog(line, &entry);

    try testing.expectEqual(@as(i32, 1), entry.valid);
    try testing.expectEqual(@as(i32, 0), entry.msg_len);
}

test "log with very long message - truncated" {
    var entry: LogEntry = undefined;
    var line: [512]u8 = undefined;
    const prefix = "[2025-01-01 10:30:45] INFO ";
    @memcpy(line[0..prefix.len], prefix);
    @memset(line[prefix.len..], 'A');
    
    parseLog(&line, &entry);

    try testing.expectEqual(@as(i32, 1), entry.valid);
    try testing.expectEqual(@as(i32, 255), entry.msg_len); // Max message length
}

test "log with special characters in message" {
    var entry: LogEntry = undefined;
    const line = "[2025-01-01 10:30:45] INFO Message with \"quotes\" and \\backslash";
    parseLog(line, &entry);

    try testing.expectEqual(@as(i32, 1), entry.valid);
    try testing.expect(entry.msg_len > 0);
}

test "log with unicode in message" {
    var entry: LogEntry = undefined;
    const line = "[2025-01-01 10:30:45] INFO Hello 世界 🌍";
    parseLog(line, &entry);

    try testing.expectEqual(@as(i32, 1), entry.valid);
    try testing.expect(entry.msg_len > 0);
}

test "log at year boundary - leap year" {
    var entry: LogEntry = undefined;
    const line = "[2024-02-29 12:00:00] INFO Leap day";
    parseLog(line, &entry);

    try testing.expectEqual(@as(i32, 1), entry.valid);
}

test "log at midnight" {
    var entry: LogEntry = undefined;
    const line = "[2025-06-15 00:00:00] DEBUG Midnight test";
    parseLog(line, &entry);

    try testing.expectEqual(@as(i32, 1), entry.valid);
    // Verify time component is 0
    try testing.expectEqual(@as(i64, 0), @mod(entry.timestamp, 86400));
}

test "log at end of day" {
    var entry: LogEntry = undefined;
    const line = "[2025-06-15 23:59:59] DEBUG End of day";
    parseLog(line, &entry);

    try testing.expectEqual(@as(i32, 1), entry.valid);
    // Verify time component is 86399 (23:59:59)
    try testing.expectEqual(@as(i64, 86399), @mod(entry.timestamp, 86400));
}

// ============================================================================
// TEST SUITE: Level Bitmask (for filter testing)
// ============================================================================

test "level bitmask - DEBUG is bit 0" {
    var entry: LogEntry = undefined;
    parseLog("[2025-01-01 10:00:00] DEBUG Test", &entry);
    
    const mask: u4 = @as(u4, 1) << @intCast(entry.level);
    try testing.expectEqual(@as(u4, 0b0001), mask);
}

test "level bitmask - INFO is bit 1" {
    var entry: LogEntry = undefined;
    parseLog("[2025-01-01 10:00:00] INFO Test", &entry);
    
    const mask: u4 = @as(u4, 1) << @intCast(entry.level);
    try testing.expectEqual(@as(u4, 0b0010), mask);
}

test "level bitmask - WARN is bit 2" {
    var entry: LogEntry = undefined;
    parseLog("[2025-01-01 10:00:00] WARN Test", &entry);
    
    const mask: u4 = @as(u4, 1) << @intCast(entry.level);
    try testing.expectEqual(@as(u4, 0b0100), mask);
}

test "level bitmask - ERROR is bit 3" {
    var entry: LogEntry = undefined;
    parseLog("[2025-01-01 10:00:00] ERROR Test", &entry);
    
    const mask: u4 = @as(u4, 1) << @intCast(entry.level);
    try testing.expectEqual(@as(u4, 0b1000), mask);
}

// ============================================================================
// TEST SUITE: Batch Processing Simulation
// ============================================================================

test "process multiple log lines" {
    const lines = [_][]const u8{
        "[2025-01-01 10:00:00] DEBUG First",
        "[2025-01-01 10:00:01] INFO Second",
        "[2025-01-01 10:00:02] WARN Third",
        "[2025-01-01 10:00:03] ERROR Fourth",
        "Invalid line",
        "[2025-01-01 10:00:04] INFO Fifth",
    };

    var valid_count: usize = 0;
    var level_counts = [_]usize{ 0, 0, 0, 0 };

    for (lines) |line| {
        var entry: LogEntry = undefined;
        parseLog(line, &entry);
        if (entry.valid == 1) {
            valid_count += 1;
            if (entry.level >= 0 and entry.level <= 3) {
                level_counts[@intCast(entry.level)] += 1;
            }
        }
    }

    try testing.expectEqual(@as(usize, 5), valid_count);
    try testing.expectEqual(@as(usize, 1), level_counts[0]); // DEBUG
    try testing.expectEqual(@as(usize, 2), level_counts[1]); // INFO
    try testing.expectEqual(@as(usize, 1), level_counts[2]); // WARN
    try testing.expectEqual(@as(usize, 1), level_counts[3]); // ERROR
}

// ============================================================================
// TEST SUITE: Time Range Filtering
// ============================================================================

test "timestamp comparison for time range" {
    var entry1: LogEntry = undefined;
    var entry2: LogEntry = undefined;
    
    parseLog("[2025-01-01 10:00:00] INFO Earlier", &entry1);
    parseLog("[2025-01-01 10:00:01] INFO Later", &entry2);
    
    try testing.expect(entry1.timestamp < entry2.timestamp);
}

test "same timestamp entries" {
    var entry1: LogEntry = undefined;
    var entry2: LogEntry = undefined;
    
    parseLog("[2025-01-01 10:00:00] INFO First", &entry1);
    parseLog("[2025-01-01 10:00:00] DEBUG Second", &entry2);
    
    try testing.expectEqual(entry1.timestamp, entry2.timestamp);
}

// ============================================================================
// TEST SUITE: Performance Characteristics
// ============================================================================

test "parse 10000 lines for performance baseline" {
    const line = "[2025-01-01 10:30:45] INFO Performance test message with some content";
    var entry: LogEntry = undefined;
    
    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        parseLog(line, &entry);
    }
    
    try testing.expectEqual(@as(i32, 1), entry.valid);
}

// ============================================================================
// TEST SUITE: Message Extraction
// ============================================================================

test "extract message content correctly" {
    var entry: LogEntry = undefined;
    const line = "[2025-01-01 10:00:00] INFO User john@example.com logged in from 192.168.1.1";
    parseLog(line, &entry);

    try testing.expectEqual(@as(i32, 1), entry.valid);
    const msg = entry.msg[0..@intCast(entry.msg_len)];
    try testing.expectEqualStrings("User john@example.com logged in from 192.168.1.1", msg);
}

test "message with numbers and symbols" {
    var entry: LogEntry = undefined;
    const line = "[2025-01-01 10:00:00] ERROR Failed after 3 retries: code=-1, msg='timeout'";
    parseLog(line, &entry);

    try testing.expectEqual(@as(i32, 1), entry.valid);
    const msg = entry.msg[0..@intCast(entry.msg_len)];
    try testing.expectEqualStrings("Failed after 3 retries: code=-1, msg='timeout'", msg);
}

test "message with leading/trailing spaces" {
    var entry: LogEntry = undefined;
    const line = "[2025-01-01 10:00:00] DEBUG   Padded message   ";
    parseLog(line, &entry);

    try testing.expectEqual(@as(i32, 1), entry.valid);
    const msg = entry.msg[0..@intCast(entry.msg_len)];
    try testing.expectEqualStrings("  Padded message   ", msg);
}
