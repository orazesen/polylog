// test_integration.zig - Integration tests using Zig's std.process
// Run with: zig test test_integration.zig
// Tests the compiled logproc binary end-to-end

const std = @import("std");
const testing = std.testing;
const fs = std.fs;

// Create a temporary test file with content
fn createTestFile(name: []const u8, content: []const u8) !void {
    const file = try fs.cwd().createFile(name, .{});
    defer file.close();
    try file.writeAll(content);
}

// Delete a test file
fn deleteTestFile(name: []const u8) void {
    fs.cwd().deleteFile(name) catch {};
}

// Helper to run logproc with arguments and capture output
fn runLogproc(allocator: std.mem.Allocator, args: []const []const u8) !struct { stdout: []u8, stderr: []u8, code: u8 } {
    // Build argv array with full path to logproc
    var argv_buf: [32][]const u8 = undefined;
    argv_buf[0] = "./output/logproc";
    for (args, 0..) |arg, i| {
        argv_buf[i + 1] = arg;
    }
    const argv = argv_buf[0 .. args.len + 1];
    
    var child = std.process.Child.init(argv, allocator);
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    
    try child.spawn();
    
    // Collect output using fixed buffers
    var stdout_buf: [65536]u8 = undefined;
    var stderr_buf: [65536]u8 = undefined;
    var stdout_len: usize = 0;
    var stderr_len: usize = 0;
    
    // Read stdout
    if (child.stdout) |pipe| {
        while (stdout_len < stdout_buf.len) {
            const n = pipe.read(stdout_buf[stdout_len..]) catch break;
            if (n == 0) break;
            stdout_len += n;
        }
    }
    
    // Read stderr
    if (child.stderr) |pipe| {
        while (stderr_len < stderr_buf.len) {
            const n = pipe.read(stderr_buf[stderr_len..]) catch break;
            if (n == 0) break;
            stderr_len += n;
        }
    }
    
    const term = try child.wait();
    const code: u8 = switch (term) {
        .Exited => |c| c,
        else => 255,
    };
    
    // Allocate and copy results
    const stdout = try allocator.alloc(u8, stdout_len);
    const stderr = try allocator.alloc(u8, stderr_len);
    @memcpy(stdout, stdout_buf[0..stdout_len]);
    @memcpy(stderr, stderr_buf[0..stderr_len]);
    
    return .{ .stdout = stdout, .stderr = stderr, .code = code };
}

fn cleanup(stdout: []u8, stderr: []u8) void {
    testing.allocator.free(stdout);
    testing.allocator.free(stderr);
}

// Check if a string contains a substring
fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// ============================================================================
// TEST SUITE: CLI Arguments
// ============================================================================

test "help displays usage" {
    const result = try runLogproc(testing.allocator, &.{"--help"});
    defer cleanup(result.stdout, result.stderr);
    
    try testing.expect(contains(result.stderr, "Usage:"));
    try testing.expectEqual(@as(u8, 0), result.code);
}

test "help shows all options" {
    const result = try runLogproc(testing.allocator, &.{"--help"});
    defer cleanup(result.stdout, result.stderr);
    
    try testing.expect(contains(result.stderr, "-t N"));
    try testing.expect(contains(result.stderr, "-l LEVELS"));
    try testing.expect(contains(result.stderr, "-o FORMAT"));
    try testing.expect(contains(result.stderr, "--stats"));
    try testing.expect(contains(result.stderr, "--split-by-level"));
    try testing.expect(contains(result.stderr, "--config"));
}

// ============================================================================
// TEST SUITE: Output Formats
// ============================================================================

test "json format produces valid json" {
    try createTestFile("_zig_test.txt", "2025-01-01 12:00:00 INFO Test message\n");
    defer deleteTestFile("_zig_test.txt");
    
    const result = try runLogproc(testing.allocator, &.{ "-o", "json", "_zig_test.txt" });
    defer cleanup(result.stdout, result.stderr);
    
    try testing.expect(std.mem.startsWith(u8, result.stdout, "{"));
    try testing.expect(contains(result.stdout, "\"level\""));
    try testing.expect(contains(result.stdout, "\"INFO\""));
}

test "jsonl format produces one json object per line" {
    try createTestFile("_zig_test.txt", "2025-01-01 12:00:00 INFO First\n2025-01-01 12:00:01 DEBUG Second\n");
    defer deleteTestFile("_zig_test.txt");
    
    const result = try runLogproc(testing.allocator, &.{ "-o", "jsonl", "_zig_test.txt" });
    defer cleanup(result.stdout, result.stderr);
    
    // Each line should be a complete JSON object
    var lines = std.mem.splitSequence(u8, result.stdout, "\n");
    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len > 0) {
            try testing.expect(std.mem.startsWith(u8, line, "{"));
            try testing.expect(std.mem.endsWith(u8, line, "}"));
            count += 1;
        }
    }
    try testing.expect(count >= 2);
}

test "csv format has header" {
    try createTestFile("_zig_test.txt", "2025-01-01 12:00:00 INFO Test\n");
    defer deleteTestFile("_zig_test.txt");
    
    const result = try runLogproc(testing.allocator, &.{ "-o", "csv", "_zig_test.txt" });
    defer cleanup(result.stdout, result.stderr);
    
    try testing.expect(std.mem.startsWith(u8, result.stdout, "level,timestamp,message"));
}

test "tsv format has header with tabs" {
    try createTestFile("_zig_test.txt", "2025-01-01 12:00:00 INFO Test\n");
    defer deleteTestFile("_zig_test.txt");
    
    const result = try runLogproc(testing.allocator, &.{ "-o", "tsv", "_zig_test.txt" });
    defer cleanup(result.stdout, result.stderr);
    
    try testing.expect(contains(result.stdout, "level\ttimestamp\tmessage"));
}

test "raw format has bracket prefix" {
    try createTestFile("_zig_test.txt", "2025-01-01 12:00:00 ERROR Problem\n");
    defer deleteTestFile("_zig_test.txt");
    
    const result = try runLogproc(testing.allocator, &.{ "-o", "raw", "_zig_test.txt" });
    defer cleanup(result.stdout, result.stderr);
    
    try testing.expect(std.mem.startsWith(u8, result.stdout, "[ERROR]"));
}

// ============================================================================
// TEST SUITE: Filtering
// ============================================================================

test "level filter only includes specified levels" {
    try createTestFile("_zig_test.txt", 
        "2025-01-01 12:00:00 INFO Keep\n" ++
        "2025-01-01 12:00:01 DEBUG Skip\n" ++
        "2025-01-01 12:00:02 ERROR Keep2\n");
    defer deleteTestFile("_zig_test.txt");
    
    const result = try runLogproc(testing.allocator, &.{ "-l", "ERROR", "-o", "raw", "_zig_test.txt" });
    defer cleanup(result.stdout, result.stderr);
    
    try testing.expect(contains(result.stdout, "[ERROR]"));
    try testing.expect(!contains(result.stdout, "[DEBUG]"));
    try testing.expect(!contains(result.stdout, "[INFO]"));
}

test "multiple level filter" {
    try createTestFile("_zig_test.txt", 
        "2025-01-01 12:00:00 INFO Keep\n" ++
        "2025-01-01 12:00:01 DEBUG Skip\n" ++
        "2025-01-01 12:00:02 WARN Keep2\n");
    defer deleteTestFile("_zig_test.txt");
    
    const result = try runLogproc(testing.allocator, &.{ "-l", "INFO,WARN", "-o", "raw", "_zig_test.txt" });
    defer cleanup(result.stdout, result.stderr);
    
    try testing.expect(contains(result.stdout, "[INFO]"));
    try testing.expect(contains(result.stdout, "[WARN]"));
    try testing.expect(!contains(result.stdout, "[DEBUG]"));
}

test "count-only produces no stdout" {
    try createTestFile("_zig_test.txt", "2025-01-01 12:00:00 INFO Test\n");
    defer deleteTestFile("_zig_test.txt");
    
    const result = try runLogproc(testing.allocator, &.{ "--count-only", "_zig_test.txt" });
    defer cleanup(result.stdout, result.stderr);
    
    try testing.expectEqual(@as(usize, 0), result.stdout.len);
    try testing.expect(contains(result.stderr, "Total:"));
    try testing.expect(contains(result.stderr, "Valid:"));
}

// ============================================================================
// TEST SUITE: Statistics
// ============================================================================

test "stats hourly shows aggregation header" {
    try createTestFile("_zig_test.txt", "2025-01-01 12:00:00 INFO Test\n");
    defer deleteTestFile("_zig_test.txt");
    
    const result = try runLogproc(testing.allocator, &.{ "--stats", "hourly", "_zig_test.txt" });
    defer cleanup(result.stdout, result.stderr);
    
    try testing.expect(contains(result.stderr, "Hourly"));
    try testing.expect(contains(result.stderr, "D:"));
    try testing.expect(contains(result.stderr, "I:"));
}

test "stats daily shows daily aggregation" {
    try createTestFile("_zig_test.txt", "2025-01-01 12:00:00 INFO Test\n");
    defer deleteTestFile("_zig_test.txt");
    
    const result = try runLogproc(testing.allocator, &.{ "--stats", "daily", "_zig_test.txt" });
    defer cleanup(result.stdout, result.stderr);
    
    try testing.expect(contains(result.stderr, "Daily"));
}

test "stats minute shows minute aggregation" {
    try createTestFile("_zig_test.txt", "2025-01-01 12:30:00 INFO Test\n");
    defer deleteTestFile("_zig_test.txt");
    
    const result = try runLogproc(testing.allocator, &.{ "--stats", "minute", "_zig_test.txt" });
    defer cleanup(result.stdout, result.stderr);
    
    try testing.expect(contains(result.stderr, "Minute"));
}

test "stats by-level shows level names" {
    try createTestFile("_zig_test.txt", 
        "2025-01-01 12:00:00 INFO Test\n" ++
        "2025-01-01 12:00:01 ERROR Err\n");
    defer deleteTestFile("_zig_test.txt");
    
    const result = try runLogproc(testing.allocator, &.{ "--stats", "by-level", "_zig_test.txt" });
    defer cleanup(result.stdout, result.stderr);
    
    try testing.expect(contains(result.stderr, "By Level"));
    try testing.expect(contains(result.stderr, "INFO:"));
    try testing.expect(contains(result.stderr, "ERROR:"));
}

// ============================================================================
// TEST SUITE: File Operations
// ============================================================================

test "output to file creates file with content" {
    try createTestFile("_zig_test.txt", "2025-01-01 12:00:00 INFO Test\n");
    defer deleteTestFile("_zig_test.txt");
    defer deleteTestFile("_zig_out.txt");
    
    const result = try runLogproc(testing.allocator, &.{ "-O", "_zig_out.txt", "_zig_test.txt" });
    defer cleanup(result.stdout, result.stderr);
    
    // Check output file exists and has content
    const out_file = try fs.cwd().openFile("_zig_out.txt", .{});
    defer out_file.close();
    const stat = try out_file.stat();
    try testing.expect(stat.size > 0);
}

test "split by level creates level files" {
    try createTestFile("_zig_test.txt", 
        "2025-01-01 12:00:00 INFO Test\n" ++
        "2025-01-01 12:00:01 ERROR Err\n" ++
        "2025-01-01 12:00:02 DEBUG Dbg\n");
    defer deleteTestFile("_zig_test.txt");
    defer deleteTestFile("debug.txt");
    defer deleteTestFile("info.txt");
    defer deleteTestFile("warn.txt");
    defer deleteTestFile("error.txt");
    
    const result = try runLogproc(testing.allocator, &.{ "--split-by-level", "_zig_test.txt" });
    defer cleanup(result.stdout, result.stderr);
    
    // Check level files exist
    const info_file = fs.cwd().openFile("info.txt", .{}) catch null;
    try testing.expect(info_file != null);
    if (info_file) |f| f.close();
    
    const error_file = fs.cwd().openFile("error.txt", .{}) catch null;
    try testing.expect(error_file != null);
    if (error_file) |f| f.close();
}

test "empty file produces zero counts" {
    try createTestFile("_zig_empty.txt", "");
    defer deleteTestFile("_zig_empty.txt");
    
    const result = try runLogproc(testing.allocator, &.{"_zig_empty.txt"});
    defer cleanup(result.stdout, result.stderr);
    
    try testing.expect(contains(result.stderr, "Total:"));
}

test "nonexistent file shows warning" {
    const result = try runLogproc(testing.allocator, &.{"_nonexistent_file_12345.txt"});
    defer cleanup(result.stdout, result.stderr);
    
    try testing.expect(contains(result.stderr, "cannot open"));
}

// ============================================================================
// TEST SUITE: Multiple Files
// ============================================================================

test "multiple files shows file count" {
    try createTestFile("_zig_test1.txt", "2025-01-01 12:00:00 INFO First\n");
    try createTestFile("_zig_test2.txt", "2025-01-01 12:00:01 INFO Second\n");
    defer deleteTestFile("_zig_test1.txt");
    defer deleteTestFile("_zig_test2.txt");
    
    const result = try runLogproc(testing.allocator, &.{ "_zig_test1.txt", "_zig_test2.txt" });
    defer cleanup(result.stdout, result.stderr);
    
    try testing.expect(contains(result.stderr, "Files:"));
}

// ============================================================================
// TEST SUITE: Performance Stats
// ============================================================================

test "performance stats are shown" {
    try createTestFile("_zig_test.txt", "2025-01-01 12:00:00 INFO Test\n");
    defer deleteTestFile("_zig_test.txt");
    
    const result = try runLogproc(testing.allocator, &.{"_zig_test.txt"});
    defer cleanup(result.stdout, result.stderr);
    
    // Check for performance section in output
    try testing.expect(contains(result.stderr, "Performance"));
    try testing.expect(contains(result.stderr, "Time:"));
}

// ============================================================================
// TEST SUITE: Invalid Input
// ============================================================================

test "invalid log lines are counted as invalid" {
    try createTestFile("_zig_test.txt", 
        "Not a valid log line\n" ++
        "Another invalid line\n" ++
        "2025-01-01 12:00:00 INFO Valid\n");
    defer deleteTestFile("_zig_test.txt");
    
    const result = try runLogproc(testing.allocator, &.{"_zig_test.txt"});
    defer cleanup(result.stdout, result.stderr);
    
    try testing.expect(contains(result.stderr, "Invalid:"));
    try testing.expect(contains(result.stderr, "Valid:"));
}

// ============================================================================
// TEST SUITE: Thread Options
// ============================================================================

test "thread count option works" {
    try createTestFile("_zig_test.txt", "2025-01-01 12:00:00 INFO Test\n");
    defer deleteTestFile("_zig_test.txt");
    
    const result = try runLogproc(testing.allocator, &.{ "-t", "2", "_zig_test.txt" });
    defer cleanup(result.stdout, result.stderr);
    
    try testing.expect(contains(result.stderr, "Valid:"));
    try testing.expectEqual(@as(u8, 0), result.code);
}
