// test_integration.zig - End-to-end tests of the compiled logproc binary
// Run with: make integration-test
// (The bare 'zig test test_integration.zig' lacks the flags the Makefile adds:
// a -target on macOS, and --cache-dir ./.zig-cache, without which zig may
// reuse a test binary that another checkout built.)
// The binaries come from the environment: LOGPROC_BIN (default ./output/logproc)
// and GENLOG_BIN (default ./output/genlog)

const std = @import("std");
const testing = std.testing;
const posix = std.posix;
const mem = std.mem;
const Child = std.process.Child;

const run_timeout_ms = 60_000; // No child process may run longer than this
const wait_timeout_ms = 10_000; // Output that is due while the child keeps running must arrive within this
const max_file_bytes = 64 * 1024 * 1024;

// ============================================================================
// Helpers: sandbox and child processes
// ============================================================================

// One per test: a private temporary directory (below .zig-cache/tmp, removed
// again by deinit, also when the test fails) that is the working directory of
// every child process, and an arena for whatever the test allocates.
const Sandbox = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    path: []const u8, // Absolute path of the directory
    logproc: []const u8, // Absolute paths of the binaries
    genlog: []const u8,

    fn init() !Sandbox {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const path = try tmp.dir.realpathAlloc(a, ".");
        const logproc = try binaryPath(a, "LOGPROC_BIN", "./output/logproc");
        const genlog = try binaryPath(a, "GENLOG_BIN", "./output/genlog");
        return .{ .arena = arena, .tmp = tmp, .path = path, .logproc = logproc, .genlog = genlog };
    }

    fn deinit(self: *Sandbox) void {
        self.tmp.cleanup();
        self.arena.deinit();
    }

    fn alloc(self: *Sandbox) mem.Allocator {
        return self.arena.allocator();
    }

    fn write(self: *Sandbox, name: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(.{ .sub_path = name, .data = data });
    }

    fn append(self: *Sandbox, name: []const u8, data: []const u8) !void {
        var file = try self.tmp.dir.openFile(name, .{ .mode = .write_only });
        defer file.close();
        try file.seekFromEnd(0);
        try file.writeAll(data);
    }

    fn read(self: *Sandbox, name: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(self.alloc(), name, max_file_bytes);
    }

    fn exists(self: *Sandbox, name: []const u8) bool {
        self.tmp.dir.access(name, .{}) catch return false;
        return true;
    }

    fn exec(self: *Sandbox, argv: []const []const u8, input: ?[]const u8, own_group: bool) !Run {
        var proc = try Proc.start(self, argv, input != null, own_group);
        defer proc.deinit();
        if (input) |data| try proc.feed(data);
        return proc.finish(self, run_timeout_ms);
    }

    // logproc ARGS, with stdin at /dev/null
    fn run(self: *Sandbox, args: []const []const u8) !Run {
        return self.exec(try self.command(self.logproc, args), null, false);
    }

    // The same, expecting exit status 0
    fn runOk(self: *Sandbox, args: []const []const u8) !Run {
        const r = try self.run(args);
        try expectExit(0, r);
        return r;
    }

    // logproc ARGS, with `input` arriving on stdin through a pipe
    fn runInput(self: *Sandbox, args: []const []const u8, input: []const u8) !Run {
        return self.exec(try self.command(self.logproc, args), input, false);
    }

    // logproc ARGS left running: the test talks to it and ends it
    fn spawn(self: *Sandbox, args: []const []const u8, stdin_pipe: bool) !Proc {
        return Proc.start(self, try self.command(self.logproc, args), stdin_pipe, false);
    }

    // /bin/sh -c SCRIPT, where "$1" is logproc and "$2" is genlog
    fn sh(self: *Sandbox, script: []const u8) !Run {
        return self.exec(&.{ "/bin/sh", "-c", script, "sh", self.logproc, self.genlog }, null, true);
    }

    // genlog COUNT NAME ARGS; returns the counts the generator reports
    fn generate(self: *Sandbox, count: []const u8, name: []const u8, args: []const []const u8) !Generated {
        const r = try self.exec(try self.command(self.genlog, try mem.concat(self.alloc(), []const u8, &.{ &.{ count, name }, args })), null, false);
        try expectExit(0, r);
        return parseGenerated(r.stderr);
    }

    fn results(self: *Sandbox, r: Run) !Results {
        errdefer std.debug.print("\nstderr:\n{s}\n", .{tail(r.stderr)});
        return parseResults(self.alloc(), r.stderr);
    }

    fn command(self: *Sandbox, exe: []const u8, args: []const []const u8) ![]const []const u8 {
        return mem.concat(self.alloc(), []const u8, &.{ &.{exe}, args });
    }
};

const Generated = struct { total: u64, valid: u64, invalid: u64 };

// The generator's summary on stderr: 'Generated: N entries (V valid, I invalid)'
fn parseGenerated(stderr: []const u8) !Generated {
    const label = "Generated: ";
    const at = mem.indexOf(u8, stderr, label) orelse return error.NoGeneratedLine;
    var words = mem.tokenizeAny(u8, stderr[at + label.len ..], " (,)\n");
    var gen: Generated = undefined;
    gen.total = parseCount(words.next() orelse "") orelse return error.BadGeneratedLine;
    _ = words.next();
    gen.valid = parseCount(words.next() orelse "") orelse return error.BadGeneratedLine;
    _ = words.next();
    gen.invalid = parseCount(words.next() orelse "") orelse return error.BadGeneratedLine;
    return gen;
}

fn binaryPath(a: mem.Allocator, variable: []const u8, default: []const u8) ![]const u8 {
    var path = default;
    if (std.process.getEnvVarOwned(a, variable)) |value| {
        if (value.len > 0) path = value;
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }
    return std.fs.cwd().realpathAlloc(a, path) catch |err| {
        std.debug.print("\ncannot find {s}: run 'make' first or set {s}\n", .{ path, variable });
        return err;
    };
}

// What a finished child left behind
const Run = struct {
    stdout: []const u8,
    stderr: []const u8,
    term: Child.Term,
    max_rss: ?usize, // Peak resident memory in bytes, where the system reports it
};

const Stream = enum { stdout, stderr };

// A running child. Its stdout and stderr are collected together, so neither
// pipe can fill up and block it, and every wait has a deadline.
const Proc = struct {
    child: Child,
    poller: std.Io.Poller(Stream),
    own_group: bool,
    feeder: ?std.Thread = null,
    reaped: bool = false,

    fn start(sb: *Sandbox, argv: []const []const u8, stdin_pipe: bool, own_group: bool) !Proc {
        var child = Child.init(argv, sb.alloc());
        child.cwd = sb.path;
        child.stdin_behavior = if (stdin_pipe) .Pipe else .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        // A shell gets its own process group, so that deinit can kill it
        // together with whatever it started
        if (own_group) child.pgid = 0;
        child.request_resource_usage_statistics = true;
        try child.spawn();
        return .{
            .child = child,
            .poller = std.Io.poll(testing.allocator, Stream, .{ .stdout = child.stdout.?, .stderr = child.stderr.? }),
            .own_group = own_group,
        };
    }

    // Kills the child if the test did not get as far as finish()
    fn deinit(self: *Proc) void {
        if (!self.reaped) {
            posix.kill(if (self.own_group) -self.child.id else self.child.id, posix.SIG.KILL) catch {};
            if (self.child.wait()) |_| {} else |_| {}
        }
        if (self.feeder) |thread| thread.join();
        self.poller.deinit();
    }

    // What the child has written so far
    fn output(self: *Proc, which: Stream) []const u8 {
        return self.poller.reader(which).buffered();
    }

    fn dump(self: *Proc) void {
        std.debug.print("\nstdout so far:\n{s}\nstderr so far:\n{s}\n", .{ tail(self.output(.stdout)), tail(self.output(.stderr)) });
    }

    // Collect output until `deadline` (in milliTimestamp terms). Returns false
    // once both streams are at their end, error.Timeout when time is up.
    fn pump(self: *Proc, deadline: i64) !bool {
        const left = deadline - std.time.milliTimestamp();
        if (left <= 0) return error.Timeout;
        return self.poller.pollTimeout(@as(u64, @intCast(left)) * std.time.ns_per_ms);
    }

    // Send all of `data` to the child's stdin from a second thread and close
    // it: a child that writes a lot before it has read everything cannot
    // deadlock the test
    fn feed(self: *Proc, data: []const u8) !void {
        const pipe = self.child.stdin.?;
        self.child.stdin = null; // The thread closes it
        self.feeder = std.Thread.spawn(.{}, writeAndClose, .{ pipe, data }) catch |err| {
            pipe.close();
            return err;
        };
    }

    fn writeAndClose(pipe: std.fs.File, data: []const u8) void {
        pipe.writeAll(data) catch {}; // The child may exit without reading (usage error)
        pipe.close();
    }

    // A small piece of input, written from this thread
    fn send(self: *Proc, data: []const u8) !void {
        try self.child.stdin.?.writeAll(data);
    }

    fn closeInput(self: *Proc) void {
        self.child.stdin.?.close();
        self.child.stdin = null;
    }

    fn signal(self: *Proc, sig: u8) !void {
        try posix.kill(self.child.id, sig);
    }

    // Collect output until `text` has appeared in a stream
    fn waitFor(self: *Proc, which: Stream, text: []const u8) !void {
        errdefer self.dump();
        const deadline = std.time.milliTimestamp() + wait_timeout_ms;
        while (!contains(self.output(which), text)) {
            if (!try self.pump(deadline)) break;
        }
        if (!contains(self.output(which), text)) return error.OutputEnded;
    }

    // Collect output until a stream holds at least `len` bytes
    fn waitForBytes(self: *Proc, which: Stream, len: usize) !void {
        errdefer self.dump();
        const deadline = std.time.milliTimestamp() + wait_timeout_ms;
        while (self.output(which).len < len) {
            if (!try self.pump(deadline)) return error.OutputEnded;
        }
    }

    // Collect output until stdout is as long as `expected`, then compare
    fn expectStdout(self: *Proc, expected: []const u8) !void {
        errdefer self.dump();
        const deadline = std.time.milliTimestamp() + wait_timeout_ms;
        while (self.output(.stdout).len < expected.len) {
            if (!try self.pump(deadline)) break;
        }
        try testing.expectEqualStrings(expected, self.output(.stdout));
    }

    // The same for a file the child writes (-O)
    fn expectFile(self: *Proc, sb: *Sandbox, name: []const u8, expected: []const u8) !void {
        errdefer self.dump();
        const deadline = std.time.milliTimestamp() + wait_timeout_ms;
        var running = true;
        while (true) {
            const content = try sb.read(name);
            if (content.len >= expected.len or !running or std.time.milliTimestamp() >= deadline) {
                return testing.expectEqualStrings(expected, content);
            }
            running = try self.idle(10);
        }
    }

    // Keep collecting for `ms` milliseconds. Returns false, at once, if both
    // streams are at their end.
    fn idle(self: *Proc, ms: i64) !bool {
        const deadline = std.time.milliTimestamp() + ms;
        while (true) {
            const more = self.pump(deadline) catch |err| switch (err) {
                error.Timeout => return true,
                else => return err,
            };
            if (!more) return false;
        }
    }

    // Collect the rest of the output and wait for the child to exit
    fn finish(self: *Proc, sb: *Sandbox, timeout_ms: i64) !Run {
        errdefer self.dump();
        const deadline = std.time.milliTimestamp() + timeout_ms;
        while (try self.pump(deadline)) {}
        const term = try self.child.wait();
        self.reaped = true;
        return .{
            .stdout = try sb.alloc().dupe(u8, self.output(.stdout)),
            .stderr = try sb.alloc().dupe(u8, self.output(.stderr)),
            .term = term,
            .max_rss = self.child.resource_usage_statistics.getMaxRss(),
        };
    }
};

// ============================================================================
// Helpers: reading what logproc printed
// ============================================================================

fn contains(haystack: []const u8, needle: []const u8) bool {
    return mem.indexOf(u8, haystack, needle) != null;
}

// The end of a long text, for failure messages
fn tail(text: []const u8) []const u8 {
    return text[text.len -| 4000..];
}

// A non-empty run of digits, nothing else
fn parseCount(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    return std.fmt.parseInt(u64, text, 10) catch null;
}

// The lines of `text`, which must end with a newline unless it is empty
fn splitLines(a: mem.Allocator, text: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var rest = text;
    while (rest.len > 0) {
        const nl = mem.indexOfScalar(u8, rest, '\n') orelse return error.MissingFinalNewline;
        try list.append(a, rest[0..nl]);
        rest = rest[nl + 1 ..];
    }
    return list.toOwnedSlice(a);
}

fn lineLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return mem.lessThan(u8, lhs, rhs);
}

// The same lines in any order: with more than one thread the order of the
// records is not fixed
fn expectSameLines(a: mem.Allocator, expected: []const u8, actual: []const u8) !void {
    const want = try splitLines(a, expected);
    const found = try splitLines(a, actual);
    mem.sort([]const u8, want, {}, lineLessThan);
    mem.sort([]const u8, found, {}, lineLessThan);
    try testing.expectEqual(want.len, found.len);
    for (want, found) |want_line, found_line| try testing.expectEqualStrings(want_line, found_line);
}

fn expectExit(expected: u8, r: Run) !void {
    switch (r.term) {
        .Exited => |code| if (code == expected) return,
        else => {},
    }
    std.debug.print("\nexpected exit status {d}, found {any}\nstderr:\n{s}\n", .{ expected, r.term, tail(r.stderr) });
    return error.UnexpectedExitStatus;
}

// The Results block on stderr:
//   === Results ===
//   Files:   N           (only with more than one input)
//   Total:   N
//   Valid:   N
//   Invalid: N
//   Matched: N
//   --- By Level ---
//   DEBUG:   N           (then INFO, WARN, ERROR)
//   --- Aggregation (Mode) ---   (only with --stats, followed by its lines)
//   --- Performance ---
const Results = struct {
    files: ?u64 = null,
    total: u64 = 0,
    valid: u64 = 0,
    invalid: u64 = 0,
    matched: ?u64 = null, // Null if the line is missing
    levels: [4]u64 = .{ 0, 0, 0, 0 }, // DEBUG, INFO, WARN, ERROR
    stats_mode: ?[]const u8 = null, // From the Aggregation header
    stats_lines: []const []const u8 = &.{},
};

fn parseResults(a: mem.Allocator, stderr: []const u8) !Results {
    const header = "=== Results ===\n";
    const at = mem.indexOf(u8, stderr, header) orelse return error.NoResultsBlock;
    const lines = try splitLines(a, stderr[at + header.len ..]);
    var i: usize = 0;
    var r: Results = .{};
    r.files = takeCount(lines, &i, "Files:   ");
    r.total = takeCount(lines, &i, "Total:   ") orelse return error.BadResultsBlock;
    r.valid = takeCount(lines, &i, "Valid:   ") orelse return error.BadResultsBlock;
    r.invalid = takeCount(lines, &i, "Invalid: ") orelse return error.BadResultsBlock;
    r.matched = takeCount(lines, &i, "Matched: ");
    if (!takeLine(lines, &i, "--- By Level ---")) return error.BadResultsBlock;
    for ([_][]const u8{ "DEBUG:   ", "INFO:    ", "WARN:    ", "ERROR:   " }, 0..) |label, level| {
        r.levels[level] = takeCount(lines, &i, label) orelse return error.BadResultsBlock;
    }
    if (i < lines.len and mem.startsWith(u8, lines[i], "--- Aggregation (") and mem.endsWith(u8, lines[i], ") ---")) {
        r.stats_mode = lines[i]["--- Aggregation (".len .. lines[i].len - ") ---".len];
        i += 1;
        const first = i;
        while (i < lines.len and !mem.eql(u8, lines[i], "--- Performance ---")) i += 1;
        r.stats_lines = lines[first..i];
    }
    if (!takeLine(lines, &i, "--- Performance ---")) return error.BadResultsBlock;
    return r;
}

// If line i is `label` followed by a number, returns the number and moves on
fn takeCount(lines: []const []const u8, i: *usize, label: []const u8) ?u64 {
    if (i.* >= lines.len or !mem.startsWith(u8, lines[i.*], label)) return null;
    const n = parseCount(lines[i.*][label.len..]) orelse return null;
    i.* += 1;
    return n;
}

fn takeLine(lines: []const []const u8, i: *usize, text: []const u8) bool {
    if (i.* >= lines.len or !mem.eql(u8, lines[i.*], text)) return false;
    i.* += 1;
    return true;
}

fn expectCounts(r: Results, total: u64, valid: u64, invalid: u64, matched: u64) !void {
    try testing.expectEqual(total, r.total);
    try testing.expectEqual(valid, r.valid);
    try testing.expectEqual(invalid, r.invalid);
    try testing.expectEqual(@as(?u64, matched), r.matched);
}

// The By Level block (valid entries, before any filter)
fn expectLevels(r: Results, debug: u64, info: u64, warn: u64, err: u64) !void {
    try testing.expectEqualSlices(u64, &.{ debug, info, warn, err }, &r.levels);
}

// The header and the lines of the Aggregation block (`expected`: one per line)
fn expectStats(r: Results, mode: []const u8, expected: []const u8) !void {
    try testing.expect(r.stats_mode != null);
    try testing.expectEqualStrings(mode, r.stats_mode.?);
    const joined = try mem.join(testing.allocator, "\n", r.stats_lines);
    defer testing.allocator.free(joined);
    try testing.expectEqualStrings(mem.trimEnd(u8, expected, "\n"), joined);
}

// A time bucket line: 'LABEL  D:n I:n W:n E:n (total:n)'
const Bucket = struct { label: []const u8, levels: [4]u64, total: u64 };

fn parseBucket(line: []const u8) !Bucket {
    const sep = mem.indexOf(u8, line, "  D:") orelse return error.BadBucketLine;
    var bucket: Bucket = .{ .label = line[0..sep], .levels = undefined, .total = undefined };
    var words = mem.splitScalar(u8, line[sep + 2 ..], ' ');
    for ("DIWE", 0..) |letter, level| {
        const word = words.next() orelse return error.BadBucketLine;
        if (word.len < 3 or word[0] != letter or word[1] != ':') return error.BadBucketLine;
        bucket.levels[level] = parseCount(word[2..]) orelse return error.BadBucketLine;
    }
    const last = words.next() orelse return error.BadBucketLine;
    if (!mem.startsWith(u8, last, "(total:") or !mem.endsWith(u8, last, ")") or words.next() != null) return error.BadBucketLine;
    bucket.total = parseCount(last["(total:".len .. last.len - 1]) orelse return error.BadBucketLine;
    return bucket;
}

// A usage or config error: exit status 1, a line starting with 'Error: ' on
// stderr, and no processing at all. Returns that line.
fn expectUsageError(r: Run) ![]const u8 {
    errdefer std.debug.print("\nstderr:\n{s}\n", .{tail(r.stderr)});
    try expectExit(1, r);
    try testing.expectEqualStrings("", r.stdout);
    try testing.expect(!contains(r.stderr, "=== Results ==="));
    var lines = mem.splitScalar(u8, r.stderr, '\n');
    while (lines.next()) |line| {
        if (mem.startsWith(u8, line, "Error: ")) return line;
    }
    return error.NoErrorLine;
}

fn printArgs(args: []const []const u8) void {
    std.debug.print("\narguments:", .{});
    for (args) |arg| std.debug.print(" '{s}'", .{arg});
    std.debug.print("\n", .{});
}

// True if `text` holds the number n as a whole run of digits
fn mentionsNumber(text: []const u8, n: u64) bool {
    var i: usize = 0;
    while (i < text.len) {
        if (!std.ascii.isDigit(text[i])) {
            i += 1;
            continue;
        }
        var end = i;
        while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
        const value: ?u64 = std.fmt.parseInt(u64, text[i..end], 10) catch null;
        if (value == n) return true;
        i = end;
    }
    return false;
}

// One record of the json and jsonl formats
const Record = struct { level: []const u8, timestamp: i64, message: []const u8 };

// jsonl: every line is one object
fn parseJsonLines(a: mem.Allocator, text: []const u8) ![]Record {
    const lines = try splitLines(a, text);
    const records = try a.alloc(Record, lines.len);
    for (lines, records) |line, *record| {
        record.* = try std.json.parseFromSliceLeaky(Record, a, line, .{});
    }
    return records;
}

// json: the whole output is one array
fn parseJsonArray(a: mem.Allocator, text: []const u8) ![]Record {
    return std.json.parseFromSliceLeaky([]Record, a, text, .{});
}

fn expectRecords(expected: []const Record, actual: []const Record) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| {
        try testing.expectEqualStrings(e.level, a.level);
        try testing.expectEqual(e.timestamp, a.timestamp);
        try testing.expectEqualStrings(e.message, a.message);
    }
}

// ============================================================================
// Shared input: five valid entries twelve hours apart and one invalid line
// ============================================================================

const sample =
    "2025-01-01 00:00:00 DEBUG cache warm\n" ++
    "2025-01-01 12:00:00 INFO User logged in\n" ++
    "2025-01-02 00:00:00 WARN Disk almost full\n" ++
    "not a log line\n" ++
    "2025-01-02 12:00:00 ERROR Connection TIMEOUT\n" ++
    "2025-01-03 00:00:00 ERROR disk failure\n";

const sample_records = [_]Record{
    .{ .level = "DEBUG", .timestamp = 1735689600, .message = "cache warm" },
    .{ .level = "INFO", .timestamp = 1735732800, .message = "User logged in" },
    .{ .level = "WARN", .timestamp = 1735776000, .message = "Disk almost full" },
    .{ .level = "ERROR", .timestamp = 1735819200, .message = "Connection TIMEOUT" },
    .{ .level = "ERROR", .timestamp = 1735862400, .message = "disk failure" },
};

const json_debug =
    \\{"level":"DEBUG","timestamp":1735689600,"message":"cache warm"}
;
const json_info =
    \\{"level":"INFO","timestamp":1735732800,"message":"User logged in"}
;
const json_warn =
    \\{"level":"WARN","timestamp":1735776000,"message":"Disk almost full"}
;
const json_timeout =
    \\{"level":"ERROR","timestamp":1735819200,"message":"Connection TIMEOUT"}
;
const json_failure =
    \\{"level":"ERROR","timestamp":1735862400,"message":"disk failure"}
;
const sample_jsonl = json_debug ++ "\n" ++ json_info ++ "\n" ++ json_warn ++ "\n" ++ json_timeout ++ "\n" ++ json_failure ++ "\n";
const sample_json = "[\n" ++ json_debug ++ ",\n" ++ json_info ++ ",\n" ++ json_warn ++ ",\n" ++ json_timeout ++ ",\n" ++ json_failure ++ "\n]\n";

const raw_debug = "[DEBUG] cache warm\n";
const raw_info = "[INFO] User logged in\n";
const raw_warn = "[WARN] Disk almost full\n";
const raw_timeout = "[ERROR] Connection TIMEOUT\n";
const raw_failure = "[ERROR] disk failure\n";
const sample_raw = raw_debug ++ raw_info ++ raw_warn ++ raw_timeout ++ raw_failure;

// The last day of each month of 2025, and the day after it that does not exist
const month_ends = [_][]const u8{
    "2025-01-31", "2025-02-28", "2025-03-31", "2025-04-30", "2025-05-31", "2025-06-30",
    "2025-07-31", "2025-08-31", "2025-09-30", "2025-10-31", "2025-11-30", "2025-12-31",
};
const past_month_ends = [_][]const u8{
    "2025-01-32", "2025-02-29", "2025-03-32", "2025-04-31", "2025-05-32", "2025-06-31",
    "2025-07-32", "2025-08-32", "2025-09-31", "2025-10-32", "2025-11-31", "2025-12-32",
};

// logproc ARGS -t 1 -o raw on the sample: the records that pass the filters,
// and the counts (By Level stays unfiltered)
fn expectFiltered(sb: *Sandbox, args: []const []const u8, records: []const u8, matched: u64) !void {
    errdefer printArgs(args);
    try sb.write("sample.txt", sample);
    const r = try sb.runOk(try mem.concat(sb.alloc(), []const u8, &.{ args, &.{ "-t", "1", "-o", "raw", "sample.txt" } }));
    try testing.expectEqualStrings(records, r.stdout);
    const res = try sb.results(r);
    try expectCounts(res, 6, 5, 1, matched);
    try expectLevels(res, 1, 1, 1, 2);
}

// ============================================================================
// TEST SUITE: Output Formats
// ============================================================================

test "jsonl: one object per line" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("sample.txt", sample);

    const r = try sb.runOk(&.{ "-t", "1", "-o", "jsonl", "sample.txt" });
    try testing.expectEqualStrings(sample_jsonl, r.stdout);
    try testing.expect(mem.indexOfScalar(u8, r.stdout, 0) == null);
    try expectRecords(&sample_records, try parseJsonLines(sb.alloc(), r.stdout));
    try expectCounts(try sb.results(r), 6, 5, 1, 5);
}

test "json: the output is one array" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("sample.txt", sample);

    // json is also the default format
    for ([_][]const []const u8{ &.{ "-t", "1", "-o", "json", "sample.txt" }, &.{ "-t", "1", "sample.txt" } }) |args| {
        const r = try sb.runOk(args);
        try testing.expectEqualStrings(sample_json, r.stdout);
        try testing.expect(mem.indexOfScalar(u8, r.stdout, 0) == null);
        try expectRecords(&sample_records, try parseJsonArray(sb.alloc(), r.stdout));
        try expectCounts(try sb.results(r), 6, 5, 1, 5);
    }
}

test "json: no records give an empty array" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("empty.txt", "");
    try sb.write("invalid.txt", "not a log line\n\nanother one\n");
    try sb.write("sample.txt", sample);

    for ([_][]const []const u8{
        &.{ "-o", "json", "empty.txt" },
        &.{ "-o", "json", "invalid.txt" },
        &.{ "-o", "json", "-m", "no such message", "sample.txt" },
    }) |args| {
        errdefer printArgs(args);
        const r = try sb.runOk(args);
        try testing.expectEqualStrings("[]\n", r.stdout);
        try testing.expectEqual(0, (try parseJsonArray(sb.alloc(), r.stdout)).len);
    }
}

test "json: many records from many threads form one document" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const gen = try sb.generate("20K", "gen.txt", &.{});

    const r = try sb.runOk(&.{ "-t", "8", "-o", "json", "gen.txt" });
    try testing.expect(mem.indexOfScalar(u8, r.stdout, 0) == null);
    try testing.expect(mem.startsWith(u8, r.stdout, "[\n{"));
    try testing.expect(mem.endsWith(u8, r.stdout, "}\n]\n"));
    const records = try parseJsonArray(sb.alloc(), r.stdout);
    try testing.expectEqual(gen.valid, records.len);
    // One object per line, each followed by a comma except the last
    try testing.expectEqual(gen.valid - 1, mem.count(u8, r.stdout, "},\n{"));
    try expectCounts(try sb.results(r), gen.total, gen.valid, gen.invalid, gen.valid);
}

test "csv: header once, message always quoted, quotes doubled" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("in.txt", "2025-01-01 12:00:00 INFO plain\n" ++
        "2025-01-01 12:00:01 WARN say \"hi\", then leave\n" ++
        "not a log line\n" ++
        "2025-01-01 12:00:02 ERROR \"\"\n");

    const r = try sb.runOk(&.{ "-t", "1", "-o", "csv", "in.txt" });
    try testing.expectEqualStrings("level,timestamp,message\n" ++
        "INFO,1735732800,\"plain\"\n" ++
        "WARN,1735732801,\"say \"\"hi\"\", then leave\"\n" ++
        "ERROR,1735732802,\"\"\"\"\"\"\n", r.stdout);
}

test "no record, no output: csv and tsv write no header" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("sample.txt", sample);

    for ([_][]const u8{ "csv", "tsv", "raw", "jsonl" }) |format| {
        const r = try sb.runOk(&.{ "-o", format, "-m", "no such message", "sample.txt" });
        try testing.expectEqualStrings("", r.stdout);
        try expectCounts(try sb.results(r), 6, 5, 1, 0);
    }
}

test "tsv: tab, backslash and carriage return in a message are escaped" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("in.txt", "2025-01-01 12:00:00 INFO plain\n" ++
        "2025-01-01 12:00:01 WARN a\tb\\c\rd\t\n" ++
        "2025-01-01 12:00:02 ERROR C:\\temp\\new\n");

    const r = try sb.runOk(&.{ "-t", "1", "-o", "tsv", "in.txt" });
    try testing.expectEqualStrings("level\ttimestamp\tmessage\n" ++
        "INFO\t1735732800\tplain\n" ++
        "WARN\t1735732801\ta\\tb\\\\c\\rd\\t\n" ++
        "ERROR\t1735732802\tC:\\\\temp\\\\new\n", r.stdout);

    // Every row has exactly three fields
    for (try splitLines(sb.alloc(), r.stdout)) |line| {
        try testing.expectEqual(2, mem.count(u8, line, "\t"));
        try testing.expect(mem.indexOfScalar(u8, line, '\r') == null);
    }
}

test "raw: level in brackets, message bytes untouched" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("in.txt", "2025-01-01 12:00:00 DEBUG d msg\n" ++
        "2025-01-01 12:00:00 INFO   two leading and two trailing blanks  \n" ++
        "2025-01-01 12:00:00 WARN \"quoted\", back\\slash\n" ++
        "2025-01-01 12:00:00 ERROR e msg\n");

    const r = try sb.runOk(&.{ "-t", "1", "-o", "raw", "in.txt" });
    try testing.expectEqualStrings("[DEBUG] d msg\n" ++
        "[INFO]   two leading and two trailing blanks  \n" ++
        "[WARN] \"quoted\", back\\slash\n" ++
        "[ERROR] e msg\n", r.stdout);
}

test "timestamps at and before the epoch are printed in every format" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("in.txt", "1969-12-31 23:59:59 INFO one second early\n" ++
        "1970-01-01 00:00:00 WARN the epoch\n" ++
        "0000-01-01 00:00:00 DEBUG year zero\n" ++
        "9999-12-31 23:59:59 ERROR far future\n");

    const csv = try sb.runOk(&.{ "-t", "1", "-o", "csv", "in.txt" });
    try testing.expectEqualStrings("level,timestamp,message\n" ++
        "INFO,-1,\"one second early\"\n" ++
        "WARN,0,\"the epoch\"\n" ++
        "DEBUG,-62167219200,\"year zero\"\n" ++
        "ERROR,253402300799,\"far future\"\n", csv.stdout);

    const tsv = try sb.runOk(&.{ "-t", "1", "-o", "tsv", "in.txt" });
    try testing.expectEqualStrings("level\ttimestamp\tmessage\n" ++
        "INFO\t-1\tone second early\n" ++
        "WARN\t0\tthe epoch\n" ++
        "DEBUG\t-62167219200\tyear zero\n" ++
        "ERROR\t253402300799\tfar future\n", tsv.stdout);

    const jsonl = try sb.runOk(&.{ "-t", "1", "-o", "jsonl", "in.txt" });
    try testing.expectEqualStrings(
        \\{"level":"INFO","timestamp":-1,"message":"one second early"}
        \\{"level":"WARN","timestamp":0,"message":"the epoch"}
        \\{"level":"DEBUG","timestamp":-62167219200,"message":"year zero"}
        \\{"level":"ERROR","timestamp":253402300799,"message":"far future"}
        \\
    , jsonl.stdout);

    const json = try sb.runOk(&.{ "-t", "1", "-o", "json", "in.txt" });
    const records = try parseJsonArray(sb.alloc(), json.stdout);
    try testing.expectEqual(4, records.len);
    try testing.expectEqual(-1, records[0].timestamp);
    try testing.expectEqual(0, records[1].timestamp);
    try testing.expectEqual(-62167219200, records[2].timestamp);
    try testing.expectEqual(253402300799, records[3].timestamp);
}

test "-O writes the records to a file and nothing to stdout" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("sample.txt", sample);

    // The closing bracket of the array has to reach the file too
    const json = try sb.runOk(&.{ "-t", "1", "-O", "out.json", "sample.txt" });
    try testing.expectEqualStrings("", json.stdout);
    try testing.expectEqualStrings(sample_json, try sb.read("out.json"));

    // An existing file is replaced
    try sb.write("out.txt", "previous content, longer than the new one" ** 10);
    const raw = try sb.runOk(&.{ "-t", "1", "-o", "raw", "-O", "out.txt", "sample.txt" });
    try testing.expectEqualStrings("", raw.stdout);
    try testing.expectEqualStrings(sample_raw, try sb.read("out.txt"));
    try expectCounts(try sb.results(raw), 6, 5, 1, 5);

    // A file that cannot be created is an error before anything is processed
    _ = try expectUsageError(try sb.run(&.{ "-O", "no-such-directory/out.txt", "sample.txt" }));
}

test "--split-by-level writes one raw file per level" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("in.txt", "2025-01-01 12:00:00 DEBUG d one\n" ++
        "2025-01-01 12:00:01 ERROR e one\n" ++
        "not a log line\n" ++
        "2025-01-01 12:00:02 INFO i one\n" ++
        "2025-01-01 12:00:03 DEBUG d two\n");

    // Raw lines whatever -o says, and no JSON document on stdout
    for ([_][]const []const u8{
        &.{ "-t", "1", "--split-by-level", "in.txt" },
        &.{ "-t", "1", "--split-by-level", "-o", "csv", "in.txt" },
        &.{ "-t", "8", "--split-by-level", "-o", "json", "in.txt" },
    }) |args| {
        errdefer printArgs(args);
        try sb.write("warn.txt", "left over from an earlier run\n");
        const r = try sb.runOk(args);
        try testing.expectEqualStrings("", r.stdout);
        try testing.expectEqualStrings("[DEBUG] d one\n[DEBUG] d two\n", try sb.read("debug.txt"));
        try testing.expectEqualStrings("[INFO] i one\n", try sb.read("info.txt"));
        try testing.expectEqualStrings("", try sb.read("warn.txt"));
        try testing.expectEqualStrings("[ERROR] e one\n", try sb.read("error.txt"));
        try expectCounts(try sb.results(r), 5, 4, 1, 4);
    }
}

// ============================================================================
// TEST SUITE: JSON Escaping
// ============================================================================

test "json escaping: quotes, backslashes and control bytes" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const a = sb.alloc();
    const message = "say \"hi\" C:\\dir tab\there bell\x07 nul\x00 cr\rmid";
    try sb.write("in.txt", "2025-01-01 12:00:00 INFO " ++ message ++ "\n");

    const jsonl = try sb.runOk(&.{ "-o", "jsonl", "in.txt" });
    try testing.expectEqualStrings(
        \\{"level":"INFO","timestamp":1735732800,"message":"say \"hi\" C:\\dir tab\there bell\u0007 nul\u0000 cr\rmid"}
        \\
    , jsonl.stdout);
    try expectRecords(&.{.{ .level = "INFO", .timestamp = 1735732800, .message = message }}, try parseJsonLines(a, jsonl.stdout));

    const json = try sb.runOk(&.{ "-o", "json", "in.txt" });
    try expectRecords(&.{.{ .level = "INFO", .timestamp = 1735732800, .message = message }}, try parseJsonArray(a, json.stdout));
}

test "json escaping: every control byte survives a round trip" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const a = sb.alloc();
    // All bytes below 0x20 except the newline, which ends the line
    var message: std.ArrayList(u8) = .empty;
    for (0..0x20) |c| {
        if (c == '\n') continue;
        try message.append(a, 'x');
        try message.append(a, @intCast(c));
    }
    try message.append(a, 'x');
    try sb.write("in.txt", try mem.concat(a, u8, &.{ "2025-01-01 12:00:00 WARN ", message.items, "\n" }));

    const r = try sb.runOk(&.{ "-o", "jsonl", "in.txt" });
    for (r.stdout[0 .. r.stdout.len - 1]) |c| try testing.expect(c >= 0x20);
    try expectRecords(&.{.{ .level = "WARN", .timestamp = 1735732800, .message = message.items }}, try parseJsonLines(a, r.stdout));
}

test "json escaping: bytes that are not UTF-8 become U+FFFD" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const a = sb.alloc();
    const bad = "\u{FFFD}"; // One per byte outside a well-formed sequence
    const cases = [_]struct { bytes: []const u8, message: []const u8 }{
        .{ .bytes = "valid \xc3\xa9 \xe2\x82\xac \xf0\x9f\x98\x80 end", .message = "valid \xc3\xa9 \xe2\x82\xac \xf0\x9f\x98\x80 end" },
        .{ .bytes = "stray continuation \x80 end", .message = "stray continuation " ++ bad ++ " end" },
        .{ .bytes = "lead without continuation \xc3x", .message = "lead without continuation " ++ bad ++ "x" },
        .{ .bytes = "overlong \xc0\xaf end", .message = "overlong " ++ bad ** 2 ++ " end" },
        .{ .bytes = "overlong three bytes \xe0\x80\xaf end", .message = "overlong three bytes " ++ bad ** 3 ++ " end" },
        .{ .bytes = "surrogate \xed\xa0\x80 end", .message = "surrogate " ++ bad ** 3 ++ " end" },
        .{ .bytes = "overlong four bytes \xf0\x80\x80\x80 end", .message = "overlong four bytes " ++ bad ** 4 ++ " end" },
        .{ .bytes = "overlong four bytes \xf0\x8f\xbf\xbf end", .message = "overlong four bytes " ++ bad ** 4 ++ " end" },
        .{ .bytes = "first four bytes \xf0\x90\x80\x80 end", .message = "first four bytes \xf0\x90\x80\x80 end" },
        .{ .bytes = "last four bytes \xf4\x8f\xbf\xbf end", .message = "last four bytes \xf4\x8f\xbf\xbf end" },
        .{ .bytes = "above U+10FFFF \xf4\x90\x80\x80 end", .message = "above U+10FFFF " ++ bad ** 4 ++ " end" },
        .{ .bytes = "lead f5 \xf5\x80\x80\x80 end", .message = "lead f5 " ++ bad ** 4 ++ " end" },
        .{ .bytes = "lead f7 \xf7\xbf\xbf\xbf end", .message = "lead f7 " ++ bad ** 4 ++ " end" },
        .{ .bytes = "invalid lead \xf8\xff end", .message = "invalid lead " ++ bad ** 2 ++ " end" },
        .{ .bytes = "cut at the end \xe2\x82", .message = "cut at the end " ++ bad ** 2 },
    };
    var input: std.ArrayList(u8) = .empty;
    for (cases) |case| {
        try input.appendSlice(a, "2025-01-01 12:00:00 ERROR ");
        try input.appendSlice(a, case.bytes);
        try input.append(a, '\n');
    }
    try sb.write("in.txt", input.items);

    for ([_][]const u8{ "jsonl", "json" }) |format| {
        const r = try sb.runOk(&.{ "-t", "1", "-o", format, "in.txt" });
        try testing.expect(std.unicode.utf8ValidateSlice(r.stdout));
        const records = if (mem.eql(u8, format, "json")) try parseJsonArray(a, r.stdout) else try parseJsonLines(a, r.stdout);
        try testing.expectEqual(cases.len, records.len);
        for (cases, records) |case, record| try testing.expectEqualStrings(case.message, record.message);
    }

    // The replacement is written as an escape
    try sb.write("one.txt", "2025-01-01 12:00:00 INFO a\x80b\n");
    const one = try sb.runOk(&.{ "-o", "jsonl", "one.txt" });
    try testing.expectEqualStrings(
        \\{"level":"INFO","timestamp":1735732800,"message":"a\ufffdb"}
        \\
    , one.stdout);
}

test "json escaping: a character cut by the 255-byte limit still gives valid JSON" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const a = sb.alloc();
    const bad = "\u{FFFD}";
    const prefix = "2025-01-01 12:00:00 INFO ";
    // The message is cut after 255 bytes, here in the middle of a character
    try sb.write("in.txt", prefix ++ "a" ** 254 ++ "\xc3\xa9 tail\n" ++
        prefix ++ "b" ** 253 ++ "\xe2\x82\xac tail\n" ++
        prefix ++ "c" ** 252 ++ "\xf0\x9f\x98\x80 tail\n" ++
        prefix ++ "d" ** 253 ++ "\xc3\xa9 tail\n" ++
        prefix ++ "e" ** 300 ++ "\n");
    const expected = [_][]const u8{
        "a" ** 254 ++ bad,
        "b" ** 253 ++ bad ** 2,
        "c" ** 252 ++ bad ** 3,
        "d" ** 253 ++ "\xc3\xa9", // Fits exactly
        "e" ** 255,
    };

    const jsonl = try sb.runOk(&.{ "-t", "1", "-o", "jsonl", "in.txt" });
    try testing.expect(std.unicode.utf8ValidateSlice(jsonl.stdout));
    const lines = try parseJsonLines(a, jsonl.stdout);
    try testing.expectEqual(expected.len, lines.len);
    for (expected, lines) |message, record| try testing.expectEqualStrings(message, record.message);

    const json = try sb.runOk(&.{ "-t", "1", "-o", "json", "in.txt" });
    const elements = try parseJsonArray(a, json.stdout);
    try testing.expectEqual(expected.len, elements.len);
    for (expected, elements) |message, record| try testing.expectEqualStrings(message, record.message);
}

// ============================================================================
// TEST SUITE: Parser Rules, Seen Through The Binary
// ============================================================================

test "parser: impossible dates and times are invalid" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const good = [_][]const u8{
        "2024-02-29 12:00:00 INFO leap day 2024",
        "2000-02-29 12:00:00 INFO leap day 2000",
        "2025-12-31 23:59:59 INFO last second of the year",
        "0000-01-01 00:00:00 INFO year 0000",
        "9999-12-31 23:59:59 INFO year 9999",
    };
    const bad = [_][]const u8{
        "2025-02-29 12:00:00 INFO no leap day in 2025",
        "2025-02-30 12:00:00 INFO february 30",
        "1900-02-29 12:00:00 INFO 1900 is not a leap year",
        "2025-04-31 12:00:00 INFO april 31",
        "2025-13-01 12:00:00 INFO month 13",
        "2025-00-10 12:00:00 INFO month 0",
        "2025-01-00 12:00:00 INFO day 0",
        "2025-01-32 12:00:00 INFO day 32",
        "2025-01-01 24:00:00 INFO hour 24",
        "2025-01-01 12:60:00 INFO minute 60",
        "2025-01-01 12:00:60 INFO second 60",
        "2025-0a-01 12:00:00 INFO letter in the month",
        "20x5-01-01 12:00:00 INFO letter in the year",
        "2025-01-01 1 :00:00 INFO blank in the hour",
        "2025/01/01 12:00:00 INFO slashes",
        "2025-01-01T12:00:00 INFO T separator",
        "2025-01-01 12.00.00 INFO dots",
    };
    var input: std.ArrayList(u8) = .empty;
    var expected: std.ArrayList(u8) = .empty;
    for (good, 0..) |line, i| {
        // Mixed with the bad ones, so that accepting one of those shows up
        // in the output too
        for (bad[i * bad.len / good.len .. (i + 1) * bad.len / good.len]) |bad_line| {
            try input.print(sb.alloc(), "{s}\n", .{bad_line});
        }
        try input.print(sb.alloc(), "{s}\n", .{line});
        try expected.print(sb.alloc(), "[INFO] {s}\n", .{line[25..]});
    }
    try sb.write("in.txt", input.items);

    const r = try sb.runOk(&.{ "-t", "1", "-o", "raw", "in.txt" });
    try testing.expectEqualStrings(expected.items, r.stdout);
    try expectCounts(try sb.results(r), good.len + bad.len, good.len, bad.len, good.len);
}

test "parser: the level is a whole uppercase word" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("in.txt", "2025-01-01 12:00:00 INFOX glued\n" ++
        "2025-01-01 12:00:00 DEBUGGING now\n" ++
        "2025-01-01 12:00:00 INFO ok\n" ++
        "2025-01-01 12:00:00 ERRORS many\n" ++
        "2025-01-01 12:00:00 WARNING soon\n" ++
        "2025-01-01 12:00:00 info lower case\n" ++
        "2025-01-01 12:00:00 Error mixed case\n" ++
        "2025-01-01 12:00:00 WARN\ttab instead of a blank\n" ++
        "2025-01-01 12:00:00 TRACE unknown level\n" ++
        "2025-01-01 12:00:00  INFO two blanks before the level\n" ++
        "2025-01-01 12:00:00 WARN  second blank belongs to the message\n");

    const r = try sb.runOk(&.{ "-t", "1", "-o", "raw", "in.txt" });
    try testing.expectEqualStrings("[INFO] ok\n[WARN]  second blank belongs to the message\n", r.stdout);
    const res = try sb.results(r);
    try expectCounts(res, 11, 2, 9, 2);
    try expectLevels(res, 0, 1, 1, 0);
}

test "parser: an empty message is valid for every level" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    // With and without the blank after the level
    try sb.write("in.txt", "2025-01-01 12:00:00 DEBUG\n" ++
        "2025-01-01 12:00:00 DEBUG \n" ++
        "2025-01-01 12:00:00 INFO\n" ++
        "2025-01-01 12:00:00 INFO \n" ++
        "2025-01-01 12:00:00 WARN\n" ++
        "2025-01-01 12:00:00 WARN \n" ++
        "2025-01-01 12:00:00 ERROR\n" ++
        "2025-01-01 12:00:00 ERROR \n");

    const r = try sb.runOk(&.{ "-t", "1", "-o", "jsonl", "in.txt" });
    try testing.expectEqualStrings(
        \\{"level":"DEBUG","timestamp":1735732800,"message":""}
        \\{"level":"DEBUG","timestamp":1735732800,"message":""}
        \\{"level":"INFO","timestamp":1735732800,"message":""}
        \\{"level":"INFO","timestamp":1735732800,"message":""}
        \\{"level":"WARN","timestamp":1735732800,"message":""}
        \\{"level":"WARN","timestamp":1735732800,"message":""}
        \\{"level":"ERROR","timestamp":1735732800,"message":""}
        \\{"level":"ERROR","timestamp":1735732800,"message":""}
        \\
    , r.stdout);
    const res = try sb.results(r);
    try expectCounts(res, 8, 8, 0, 8);
    try expectLevels(res, 2, 2, 2, 2);
}

test "parser: CRLF line endings" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    // One carriage return before the newline is dropped, a second one is data
    try sb.write("in.txt", "2025-01-01 12:00:00 INFO windows line\r\n" ++
        "2025-01-01 12:00:01 ERROR\r\n" ++
        "\r\n" ++
        "2025-01-01 12:00:02 WARN two of them\r\r\n" ++
        "2025-01-01 12:00:03 DEBUG last line without a newline\r");

    const r = try sb.runOk(&.{ "-t", "1", "-o", "jsonl", "in.txt" });
    try testing.expectEqualStrings(
        \\{"level":"INFO","timestamp":1735732800,"message":"windows line"}
        \\{"level":"ERROR","timestamp":1735732801,"message":""}
        \\{"level":"WARN","timestamp":1735732802,"message":"two of them\r"}
        \\{"level":"DEBUG","timestamp":1735732803,"message":"last line without a newline"}
        \\
    , r.stdout);
    try expectCounts(try sb.results(r), 5, 4, 1, 4);
}

// ============================================================================
// TEST SUITE: Filtering
// ============================================================================

test "-l: a single level" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try expectFiltered(&sb, &.{ "-l", "ERROR" }, raw_timeout ++ raw_failure, 2);
    try expectFiltered(&sb, &.{ "-l", "DEBUG" }, raw_debug, 1);
}

test "-l: several levels" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try expectFiltered(&sb, &.{ "-l", "INFO,WARN" }, raw_info ++ raw_warn, 2);
    try expectFiltered(&sb, &.{ "-l", "ERROR,DEBUG" }, raw_debug ++ raw_timeout ++ raw_failure, 3);
    try expectFiltered(&sb, &.{ "-l", "DEBUG,INFO,WARN,ERROR" }, sample_raw, 5);
}

test "-l: names in any case" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try expectFiltered(&sb, &.{ "-l", "error" }, raw_timeout ++ raw_failure, 2);
    try expectFiltered(&sb, &.{ "-l", "Warn,eRRoR" }, raw_warn ++ raw_timeout ++ raw_failure, 3);
}

test "-l: an unknown level or an empty list is an error" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("sample.txt", sample);
    // A prefix of a name is not the name
    for ([_][]const u8{ "FATAL", "INFO,FATAL", "ERRORS", "", "ERR", "W", "INF", "ERROR,D", "i", "INFO WARN", "INFO,,WARN", "INFO," }) |levels| {
        errdefer std.debug.print("\nlevels: '{s}'\n", .{levels});
        _ = try expectUsageError(try sb.run(&.{ "-l", levels, "-o", "raw", "sample.txt" }));
    }
}

test "-m: substring match that ignores case" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try expectFiltered(&sb, &.{ "-m", "logged" }, raw_info, 1);
    try expectFiltered(&sb, &.{ "-m", "timeout" }, raw_timeout, 1);
    try expectFiltered(&sb, &.{ "-m", "DISK" }, raw_warn ++ raw_failure, 2);
    try expectFiltered(&sb, &.{ "-m", "disk f" }, raw_failure, 1);
    try expectFiltered(&sb, &.{ "-m", "no such message" }, "", 0);
}

test "-m: an empty pattern means no filter" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try expectFiltered(&sb, &.{ "-m", "" }, sample_raw, 5);
    try expectFiltered(&sb, &.{ "-l", "ERROR", "-m", "" }, raw_timeout ++ raw_failure, 2);
}

test "-m: a pattern longer than 255 bytes is cut to 255" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("in.txt", "2025-01-01 12:00:00 INFO " ++ "a" ** 255 ++ "\n" ++
        "2025-01-01 12:00:01 INFO " ++ "a" ** 254 ++ "\n");
    for ([_]struct { pattern: []const u8, matched: u64 }{
        .{ .pattern = "a" ** 254, .matched = 2 },
        .{ .pattern = "a" ** 255, .matched = 1 },
        .{ .pattern = "A" ** 300, .matched = 1 },
    }) |case| {
        const r = try sb.runOk(&.{ "-m", case.pattern, "--count-only", "in.txt" });
        try expectCounts(try sb.results(r), 2, 2, 0, case.matched);
    }
}

test "--after and --before include both ends" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const middle = raw_info ++ raw_warn ++ raw_timeout;
    try expectFiltered(&sb, &.{ "--after", "2025-01-01 12:00:00", "--before", "2025-01-02 12:00:00" }, middle, 3);
    // One second inside each bound
    try expectFiltered(&sb, &.{ "--after", "2025-01-01 12:00:01", "--before", "2025-01-02 12:00:00" }, raw_warn ++ raw_timeout, 2);
    try expectFiltered(&sb, &.{ "--after", "2025-01-01 12:00:00", "--before", "2025-01-02 11:59:59" }, raw_info ++ raw_warn, 2);
    // Each bound on its own
    try expectFiltered(&sb, &.{ "--after", "2025-01-02 12:00:00" }, raw_timeout ++ raw_failure, 2);
    try expectFiltered(&sb, &.{ "--before", "2025-01-01 12:00:00" }, raw_debug ++ raw_info, 2);
    try expectFiltered(&sb, &.{ "--after", "2025-01-02 00:00:00", "--before", "2025-01-02 00:00:00" }, raw_warn, 1);
}

test "--after and --before: a date alone means midnight" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try expectFiltered(&sb, &.{ "--after", "2025-01-02" }, raw_warn ++ raw_timeout ++ raw_failure, 3);
    try expectFiltered(&sb, &.{ "--before", "2025-01-02" }, raw_debug ++ raw_info ++ raw_warn, 3);
    try expectFiltered(&sb, &.{ "--after", "2025-01-02", "--before", "2025-01-03" }, raw_warn ++ raw_timeout ++ raw_failure, 3);
}

test "--before alone keeps entries from before 1970" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("in.txt", "1969-07-20 20:17:00 INFO moon\n" ++
        "1970-01-01 00:00:00 WARN epoch\n" ++
        "2025-01-01 00:00:00 ERROR later\n");
    for ([_]struct { args: []const []const u8, records: []const u8 }{
        .{ .args = &.{ "--before", "1970-01-01" }, .records = "[INFO] moon\n[WARN] epoch\n" },
        .{ .args = &.{ "--before", "1969-12-31 23:59:59" }, .records = "[INFO] moon\n" },
        .{ .args = &.{ "--after", "1969-07-20 20:17:00", "--before", "1969-07-20 20:17:00" }, .records = "[INFO] moon\n" },
        .{ .args = &.{ "--after", "1969-07-21" }, .records = "[WARN] epoch\n[ERROR] later\n" },
    }) |case| {
        errdefer printArgs(case.args);
        const r = try sb.runOk(try mem.concat(sb.alloc(), []const u8, &.{ case.args, &.{ "-t", "1", "-o", "raw", "in.txt" } }));
        try testing.expectEqualStrings(case.records, r.stdout);
    }
}

test "--after and --before: an invalid value is an error" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("sample.txt", sample);
    for ([_][]const u8{ "--after", "--before" }) |option| {
        for (past_month_ends ++ [_][]const u8{
            "2025-13-01",
            "2025-00-10",
            "2025-01-00",
            "2025-02-30",
            "1900-02-29",
            "2100-02-29",
            "2025-04-31 12:00:00",
            "2025-01-01 24:00:00",
            "2025-01-01 12:60:00",
            "2025-01-01 12:00:60",
            "2025-1-1",
            "2025-01-01 12:00",
            "2025-01-01T12:00:00",
            "2025-01-01 ",
            "20250101",
            "2025-01-0x",
            "yesterday",
            "",
        }) |value| {
            errdefer std.debug.print("\n{s} '{s}'\n", .{ option, value });
            _ = try expectUsageError(try sb.run(&.{ option, value, "-o", "raw", "sample.txt" }));
        }
    }
}

test "--after and --before: the last day of every month and the leap days are accepted" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const a = sb.alloc();
    // One entry at noon of the last day of each month
    var input: std.ArrayList(u8) = .empty;
    for (month_ends) |date| try input.print(a, "{s} 12:00:00 INFO end of the month\n", .{date});
    try sb.write("months.txt", input.items);
    for (month_ends, 0..) |date, i| {
        errdefer std.debug.print("\ndate: {s}\n", .{date});
        const after = try sb.runOk(&.{ "--after", date, "--count-only", "months.txt" });
        try expectCounts(try sb.results(after), 12, 12, 0, 12 - i);
        const end_of_day = try std.fmt.allocPrint(a, "{s} 23:59:59", .{date});
        const before = try sb.runOk(&.{ "--before", end_of_day, "--count-only", "months.txt" });
        try expectCounts(try sb.results(before), 12, 12, 0, i + 1);
    }

    // February 29 exists in 2000 and in 2024
    try sb.write("leap.txt", "2000-02-28 23:59:59 DEBUG day before\n" ++
        "2000-02-29 00:00:00 INFO leap day 2000\n" ++
        "2024-02-29 12:00:00 WARN leap day 2024\n" ++
        "2024-03-01 00:00:00 ERROR day after\n");
    for ([_]struct { args: []const []const u8, records: []const u8 }{
        .{ .args = &.{ "--after", "2000-02-29" }, .records = "[INFO] leap day 2000\n[WARN] leap day 2024\n[ERROR] day after\n" },
        .{ .args = &.{ "--before", "2000-02-29" }, .records = "[DEBUG] day before\n[INFO] leap day 2000\n" },
        .{ .args = &.{ "--after", "2024-02-29" }, .records = "[WARN] leap day 2024\n[ERROR] day after\n" },
        .{ .args = &.{ "--after", "2024-02-29", "--before", "2024-02-29 23:59:59" }, .records = "[WARN] leap day 2024\n" },
        .{ .args = &.{ "--after", "2000-02-29 00:00:01", "--before", "2024-02-29" }, .records = "" },
    }) |case| {
        errdefer printArgs(case.args);
        const r = try sb.runOk(try mem.concat(a, []const u8, &.{ case.args, &.{ "-t", "1", "-o", "raw", "leap.txt" } }));
        try testing.expectEqualStrings(case.records, r.stdout);
    }

    // The same through a config file
    try sb.write("test.conf", "after = 2000-02-29\nbefore = 2024-02-29 23:59:59\n");
    const r = try sb.runOk(&.{ "--config", "test.conf", "-t", "1", "-o", "raw", "leap.txt" });
    try testing.expectEqualStrings("[INFO] leap day 2000\n[WARN] leap day 2024\n", r.stdout);
}

test "--after later than --before is an error" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("sample.txt", sample);
    _ = try expectUsageError(try sb.run(&.{ "--after", "2025-01-02", "--before", "2025-01-01", "sample.txt" }));
    _ = try expectUsageError(try sb.run(&.{ "--before", "2025-01-01 11:59:59", "--after", "2025-01-01 12:00:00", "sample.txt" }));
}

test "filters combine" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try expectFiltered(&sb, &.{ "-l", "WARN,ERROR", "-m", "disk" }, raw_warn ++ raw_failure, 2);
    try expectFiltered(&sb, &.{ "-l", "WARN,ERROR", "-m", "disk", "--after", "2025-01-02 00:00:01" }, raw_failure, 1);
    try expectFiltered(&sb, &.{ "-l", "ERROR", "--before", "2025-01-02 12:00:00" }, raw_timeout, 1);
    try expectFiltered(&sb, &.{ "-m", "o", "--after", "2025-01-01 12:00:00", "--before", "2025-01-02" }, raw_info ++ raw_warn, 2);
    try expectFiltered(&sb, &.{ "-l", "DEBUG", "-m", "disk" }, "", 0);
}

test "Matched counts the entries that pass the filters" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("sample.txt", sample);
    for ([_]struct { args: []const []const u8, matched: u64 }{
        .{ .args = &.{}, .matched = 5 },
        .{ .args = &.{ "-l", "ERROR" }, .matched = 2 },
        .{ .args = &.{ "-m", "disk" }, .matched = 2 },
        .{ .args = &.{ "--after", "2025-01-02" }, .matched = 3 },
        .{ .args = &.{ "-l", "INFO", "-m", "disk" }, .matched = 0 },
    }) |case| {
        errdefer printArgs(case.args);
        const r = try sb.runOk(try mem.concat(sb.alloc(), []const u8, &.{ case.args, &.{ "--count-only", "sample.txt" } }));
        try testing.expectEqualStrings("", r.stdout);
        const res = try sb.results(r);
        try expectCounts(res, 6, 5, 1, case.matched);
        try expectLevels(res, 1, 1, 1, 2);
    }
}

// ============================================================================
// TEST SUITE: Statistics
// ============================================================================

// Out of time order, with entries on both sides of the epoch
const stats_input =
    "2025-01-02 09:30:30 INFO e\n" ++
    "2025-01-01 10:45:00 ERROR c\n" ++
    "1970-01-01 00:00:10 DEBUG just after the epoch\n" ++
    "not a log line\n" ++
    "2025-01-01 10:15:00 INFO a\n" ++
    "2025-01-01 11:00:00 DEBUG d\n" ++
    "1969-12-31 23:59:30 ERROR just before the epoch\n" ++
    "2025-01-01 10:15:59 WARN b\n";

fn expectSampleStats(mode: []const u8, header: []const u8, expected: []const u8) !void {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("in.txt", stats_input);
    for ([_][]const u8{ "1", "8" }) |threads| {
        const r = try sb.runOk(&.{ "-t", threads, "--stats", mode, "in.txt" });
        try testing.expectEqualStrings("", r.stdout);
        const res = try sb.results(r);
        try expectStats(res, header, expected);
        try expectCounts(res, 8, 7, 1, 7);
        try expectLevels(res, 2, 2, 1, 2);
    }
}

test "--stats hourly: one line per hour, in time order" {
    try expectSampleStats("hourly", "Hourly",
        \\1969-12-31 23:00  D:0 I:0 W:0 E:1 (total:1)
        \\1970-01-01 00:00  D:1 I:0 W:0 E:0 (total:1)
        \\2025-01-01 10:00  D:0 I:1 W:1 E:1 (total:3)
        \\2025-01-01 11:00  D:1 I:0 W:0 E:0 (total:1)
        \\2025-01-02 09:00  D:0 I:1 W:0 E:0 (total:1)
    );
}

test "--stats daily: one line per day, in time order" {
    try expectSampleStats("daily", "Daily",
        \\1969-12-31  D:0 I:0 W:0 E:1 (total:1)
        \\1970-01-01  D:1 I:0 W:0 E:0 (total:1)
        \\2025-01-01  D:1 I:1 W:1 E:1 (total:4)
        \\2025-01-02  D:0 I:1 W:0 E:0 (total:1)
    );
}

test "--stats minute: one line per minute, in time order" {
    try expectSampleStats("minute", "Minute",
        \\1969-12-31 23:59  D:0 I:0 W:0 E:1 (total:1)
        \\1970-01-01 00:00  D:1 I:0 W:0 E:0 (total:1)
        \\2025-01-01 10:15  D:0 I:1 W:1 E:0 (total:2)
        \\2025-01-01 10:45  D:0 I:0 W:0 E:1 (total:1)
        \\2025-01-01 11:00  D:1 I:0 W:0 E:0 (total:1)
        \\2025-01-02 09:30  D:0 I:1 W:0 E:0 (total:1)
    );
}

test "--stats by-level: always DEBUG, INFO, WARN, ERROR" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    // ERROR comes first and INFO is missing
    try sb.write("in.txt", "2025-01-01 10:00:00 ERROR e one\n" ++
        "2025-01-01 10:00:01 WARN w one\n" ++
        "2025-01-01 10:00:02 ERROR e two\n" ++
        "2025-01-01 10:00:03 DEBUG d one\n");

    const r = try sb.runOk(&.{ "--stats", "by-level", "in.txt" });
    try testing.expectEqualStrings("", r.stdout);
    const res = try sb.results(r);
    try expectStats(res, "By Level",
        \\DEBUG : 1
        \\INFO  : 0
        \\WARN  : 1
        \\ERROR : 2
    );
    try expectCounts(res, 4, 4, 0, 4);
}

test "--stats counts the matched entries only" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("sample.txt", sample);

    const by_level = try sb.runOk(&.{ "--stats", "by-level", "-l", "info,error", "sample.txt" });
    var res = try sb.results(by_level);
    try expectStats(res, "By Level",
        \\DEBUG : 0
        \\INFO  : 1
        \\WARN  : 0
        \\ERROR : 2
    );
    try expectCounts(res, 6, 5, 1, 3);
    try expectLevels(res, 1, 1, 1, 2);

    const daily = try sb.runOk(&.{ "--stats", "daily", "-m", "disk", "sample.txt" });
    res = try sb.results(daily);
    try expectStats(res, "Daily",
        \\2025-01-02  D:0 I:0 W:1 E:0 (total:1)
        \\2025-01-03  D:0 I:0 W:0 E:1 (total:1)
    );
    try expectCounts(res, 6, 5, 1, 2);

    // Nothing matched: the header stays, by-level keeps its four lines
    const none = try sb.runOk(&.{ "--stats", "hourly", "-m", "no such message", "sample.txt" });
    try expectStats(try sb.results(none), "Hourly", "");
    const none_by_level = try sb.runOk(&.{ "--stats", "by-level", "-m", "no such message", "sample.txt" });
    try expectStats(try sb.results(none_by_level), "By Level",
        \\DEBUG : 0
        \\INFO  : 0
        \\WARN  : 0
        \\ERROR : 0
    );
}

// Checks the time bucket lines of a run on input generated between `start`
// and `end` (strictly ascending, inside the range, levels adding up to the
// total) and returns their sums
fn sumBuckets(res: Results, start: []const u8, end: []const u8) !Bucket {
    var sum: Bucket = .{ .label = "", .levels = .{ 0, 0, 0, 0 }, .total = 0 };
    var previous: []const u8 = "";
    for (res.stats_lines) |line| {
        errdefer std.debug.print("\nbucket line: {s}\n", .{line});
        const bucket = try parseBucket(line);
        // Labels have a fixed width, so text order is time order
        try testing.expect(mem.lessThan(u8, previous, bucket.label));
        try testing.expect(!mem.lessThan(u8, bucket.label, start[0..@min(start.len, bucket.label.len)]));
        try testing.expect(mem.lessThan(u8, bucket.label, end));
        try testing.expectEqual(bucket.total, bucket.levels[0] + bucket.levels[1] + bucket.levels[2] + bucket.levels[3]);
        for (&sum.levels, bucket.levels) |*level_sum, n| level_sum.* += n;
        sum.total += bucket.total;
        previous = bucket.label;
    }
    return sum;
}

// Generated input spread over more buckets than the 8760 the aggregation
// once had room for: no entry may be dropped
fn expectNoBucketDropped(mode: []const u8, start: []const u8, end: []const u8) !void {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const gen = try sb.generate("200K", "gen.txt", &.{ "--start", start, "--end", end });

    // Without a filter every valid entry is in some bucket
    const all = try sb.runOk(&.{ "-t", "8", "--stats", mode, "gen.txt" });
    try testing.expectEqualStrings("", all.stdout);
    const res = try sb.results(all);
    try testing.expect(res.stats_lines.len > 8760);
    const sum = try sumBuckets(res, start, end);
    try testing.expectEqual(gen.valid, sum.total);
    try testing.expectEqualSlices(u64, &res.levels, &sum.levels);
    try expectCounts(res, gen.total, gen.valid, gen.invalid, sum.total);

    // With a filter the buckets hold what matched
    const some = try sb.runOk(&.{ "-t", "8", "--stats", mode, "-l", "WARN,ERROR", "gen.txt" });
    const some_res = try sb.results(some);
    try testing.expect(some_res.stats_lines.len > 8760);
    const some_sum = try sumBuckets(some_res, start, end);
    try testing.expectEqualSlices(u64, &.{ 0, 0, res.levels[2], res.levels[3] }, &some_sum.levels);
    try expectCounts(some_res, gen.total, gen.valid, gen.invalid, some_sum.total);
}

test "--stats hourly: more than 8760 hours, bucket totals add up to Matched" {
    try expectNoBucketDropped("hourly", "2020-01-01", "2023-01-01");
}

test "--stats minute: more than 8760 minutes, bucket totals add up to Matched" {
    try expectNoBucketDropped("minute", "2024-02-25", "2024-03-10");
}

test "--stats: a bucket holds any number of entries" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const a = sb.alloc();
    // Counts on both sides of 256 and of 65536, each in a minute of its own
    const groups = [_]struct { minute: u8, level: []const u8, count: usize }{
        .{ .minute = 0, .level = "DEBUG", .count = 255 },
        .{ .minute = 1, .level = "INFO", .count = 256 },
        .{ .minute = 2, .level = "WARN", .count = 257 },
        .{ .minute = 3, .level = "ERROR", .count = 512 },
        .{ .minute = 4, .level = "DEBUG", .count = 65536 },
        .{ .minute = 5, .level = "INFO", .count = 65537 },
    };
    var input: std.ArrayList(u8) = .empty;
    for (groups) |group| {
        const line = try std.fmt.allocPrint(a, "2025-06-01 10:0{d}:30 {s} x\n", .{ group.minute, group.level });
        try input.ensureUnusedCapacity(a, line.len * group.count);
        for (0..group.count) |_| input.appendSliceAssumeCapacity(line);
    }
    // A few entries 64 and 128 minutes after the large groups: nothing of
    // those may show up here
    try input.appendSlice(a, "2025-06-01 11:08:30 WARN x\n" ** 3 ++ "2025-06-01 12:13:30 ERROR x\n" ** 2);
    try sb.write("in.txt", input.items);

    // The larger groups are spread over several workers
    for ([_][]const u8{ "1", "8" }) |threads| {
        errdefer std.debug.print("\n-t {s}\n", .{threads});
        const minute = try sb.results(try sb.runOk(&.{ "-t", threads, "--stats", "minute", "in.txt" }));
        try expectStats(minute, "Minute",
            \\2025-06-01 10:00  D:255 I:0 W:0 E:0 (total:255)
            \\2025-06-01 10:01  D:0 I:256 W:0 E:0 (total:256)
            \\2025-06-01 10:02  D:0 I:0 W:257 E:0 (total:257)
            \\2025-06-01 10:03  D:0 I:0 W:0 E:512 (total:512)
            \\2025-06-01 10:04  D:65536 I:0 W:0 E:0 (total:65536)
            \\2025-06-01 10:05  D:0 I:65537 W:0 E:0 (total:65537)
            \\2025-06-01 11:08  D:0 I:0 W:3 E:0 (total:3)
            \\2025-06-01 12:13  D:0 I:0 W:0 E:2 (total:2)
        );
        try expectCounts(minute, 132358, 132358, 0, 132358);
        const hourly = try sb.results(try sb.runOk(&.{ "-t", threads, "--stats", "hourly", "in.txt" }));
        try expectStats(hourly, "Hourly",
            \\2025-06-01 10:00  D:65791 I:65793 W:257 E:512 (total:132353)
            \\2025-06-01 11:00  D:0 I:0 W:3 E:0 (total:3)
            \\2025-06-01 12:00  D:0 I:0 W:0 E:2 (total:2)
        );
        const daily = try sb.results(try sb.runOk(&.{ "-t", threads, "--stats", "daily", "in.txt" }));
        try expectStats(daily, "Daily", "2025-06-01  D:65791 I:65793 W:260 E:514 (total:132358)");
        const by_level = try sb.results(try sb.runOk(&.{ "-t", threads, "--stats", "by-level", "in.txt" }));
        try expectStats(by_level, "By Level",
            \\DEBUG : 65791
            \\INFO  : 65793
            \\WARN  : 260
            \\ERROR : 514
        );
    }
}

test "--stats: the first and the last minute of the calendar" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("in.txt", "9999-12-31 23:59:59 ERROR last second\n" ++
        "0000-01-01 00:00:00 DEBUG first second\n" ++
        "1970-01-01 00:00:00 INFO the epoch\n" ++
        "0000-01-01 00:00:59 WARN same minute as the first\n" ++
        "0000-01-01 01:04:00 INFO a little later\n");

    for ([_][]const u8{ "1", "8" }) |threads| {
        const minute = try sb.results(try sb.runOk(&.{ "-t", threads, "--stats", "minute", "in.txt" }));
        try expectStats(minute, "Minute",
            \\0000-01-01 00:00  D:1 I:0 W:1 E:0 (total:2)
            \\0000-01-01 01:04  D:0 I:1 W:0 E:0 (total:1)
            \\1970-01-01 00:00  D:0 I:1 W:0 E:0 (total:1)
            \\9999-12-31 23:59  D:0 I:0 W:0 E:1 (total:1)
        );
        const hourly = try sb.results(try sb.runOk(&.{ "-t", threads, "--stats", "hourly", "in.txt" }));
        try expectStats(hourly, "Hourly",
            \\0000-01-01 00:00  D:1 I:0 W:1 E:0 (total:2)
            \\0000-01-01 01:00  D:0 I:1 W:0 E:0 (total:1)
            \\1970-01-01 00:00  D:0 I:1 W:0 E:0 (total:1)
            \\9999-12-31 23:00  D:0 I:0 W:0 E:1 (total:1)
        );
        const daily = try sb.results(try sb.runOk(&.{ "-t", threads, "--stats", "daily", "in.txt" }));
        try expectStats(daily, "Daily",
            \\0000-01-01  D:1 I:1 W:1 E:0 (total:3)
            \\1970-01-01  D:0 I:1 W:0 E:0 (total:1)
            \\9999-12-31  D:0 I:0 W:0 E:1 (total:1)
        );
    }
}

// ============================================================================
// TEST SUITE: Inputs
// ============================================================================

test "stdin: input that ends with a newline" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const r = try sb.runInput(&.{ "-t", "1", "-o", "raw" }, sample);
    try expectExit(0, r);
    try testing.expectEqualStrings(sample_raw, r.stdout);
    try expectCounts(try sb.results(r), 6, 5, 1, 5);
}

test "stdin: input without a trailing newline" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const input = sample[0 .. sample.len - 1];
    const r = try sb.runInput(&.{ "-t", "1", "-o", "raw" }, input);
    try expectExit(0, r);
    try testing.expectEqualStrings(sample_raw, r.stdout);
    try expectCounts(try sb.results(r), 6, 5, 1, 5);

    const many = try sb.runInput(&.{ "-t", "8", "-o", "raw" }, input);
    try expectExit(0, many);
    try expectSameLines(sb.alloc(), sample_raw, many.stdout);
    try expectCounts(try sb.results(many), 6, 5, 1, 5);

    // The only line has no newline
    const one = try sb.runInput(&.{ "-o", "raw" }, "2025-01-01 12:00:00 WARN only line");
    try expectExit(0, one);
    try testing.expectEqualStrings("[WARN] only line\n", one.stdout);
    try expectCounts(try sb.results(one), 1, 1, 0, 1);

    // No input at all
    const none = try sb.runInput(&.{}, "");
    try expectExit(0, none);
    try testing.expectEqualStrings("[]\n", none.stdout);
    try expectCounts(try sb.results(none), 0, 0, 0, 0);
}

test "stdin: lines split across pipe writes" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    var proc = try sb.spawn(&.{ "-t", "1", "-o", "raw" }, true);
    defer proc.deinit();
    for ([_][]const u8{
        "2025-01-01 12:00:00 INFO fir",
        "st\n2025-01-01 12:00:01 ERR",
        "OR second\nnot a ",
        "log line\n2025-01-01 12:00:02 DEBUG third\n",
    }) |piece| {
        try proc.send(piece);
        _ = try proc.idle(20); // Lets logproc read the piece on its own
    }
    proc.closeInput();
    const r = try proc.finish(&sb, run_timeout_ms);
    try expectExit(0, r);
    try testing.expectEqualStrings("[INFO] first\n[ERROR] second\n[DEBUG] third\n", r.stdout);
    try expectCounts(try sb.results(r), 4, 3, 1, 3);
}

test "stdin: lines are processed while the pipe is still open" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const a = sb.alloc();
    // About 560 KB of input (less than one read buffer) for 350 KB of output
    var input: std.ArrayList(u8) = .empty;
    var expected: std.ArrayList(u8) = .empty;
    for (0..12000) |i| {
        try input.print(a, "2025-01-01 12:00:00 INFO message number {d:0>6}\n", .{i});
        try expected.print(a, "[INFO] message number {d:0>6}\n", .{i});
    }

    var proc = try sb.spawn(&.{ "-t", "1", "-o", "raw" }, true);
    defer proc.deinit();
    var rest: []const u8 = input.items;
    while (rest.len > 0) {
        const len = @min(rest.len, 8192);
        try proc.send(rest[0..len]);
        _ = try proc.idle(1);
        rest = rest[len..];
    }
    // The input has not ended, but what has arrived is processed: the
    // records come out, one output buffer at a time
    try proc.waitForBytes(.stdout, 200_000);

    proc.closeInput();
    const r = try proc.finish(&sb, run_timeout_ms);
    try expectExit(0, r);
    try testing.expectEqualStrings(expected.items, r.stdout);
    try expectCounts(try sb.results(r), 12000, 12000, 0, 12000);
}

test "stdin: records from a slow pipe are written while it is still open" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    for ([_][]const u8{ "1", "4" }) |threads| {
        errdefer std.debug.print("\n-t {s}\n", .{threads});
        var proc = try sb.spawn(&.{ "-t", threads, "-o", "raw" }, true);
        defer proc.deinit();
        // Far less than an output buffer: a record still comes out as soon as
        // its line is processed, not when the buffer is full or the input ends
        try proc.send("2025-01-01 12:00:00 INFO first\n");
        try proc.expectStdout("[INFO] first\n");
        try proc.send("not a log line\n2025-01-01 12:00:01 WARN second\n2025-01-01 12:00:02 ERR");
        try proc.expectStdout("[INFO] first\n[WARN] second\n");
        // The unfinished line waits for its end
        _ = try proc.idle(200);
        try testing.expectEqualStrings("[INFO] first\n[WARN] second\n", proc.output(.stdout));
        try proc.send("OR third\n");
        try proc.expectStdout("[INFO] first\n[WARN] second\n[ERROR] third\n");

        proc.closeInput();
        const r = try proc.finish(&sb, run_timeout_ms);
        try expectExit(0, r);
        try testing.expectEqualStrings("[INFO] first\n[WARN] second\n[ERROR] third\n", r.stdout);
        try expectCounts(try sb.results(r), 4, 3, 1, 3);
    }
}

test "file: last line without a newline" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("in.txt", sample[0 .. sample.len - 1]);
    const r = try sb.runOk(&.{ "-t", "1", "-o", "raw", "in.txt" });
    try testing.expectEqualStrings(sample_raw, r.stdout);
    try expectCounts(try sb.results(r), 6, 5, 1, 5);
}

test "file: empty file and blank lines" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("empty.txt", "");
    const empty = try sb.runOk(&.{ "-o", "raw", "empty.txt" });
    try testing.expectEqualStrings("", empty.stdout);
    const res = try sb.results(empty);
    try expectCounts(res, 0, 0, 0, 0);
    try expectLevels(res, 0, 0, 0, 0);

    // A blank line is a line, and an invalid one
    try sb.write("blank.txt", "\n\n2025-01-01 12:00:00 INFO between blank lines\n\n");
    const blank = try sb.runOk(&.{ "-o", "raw", "blank.txt" });
    try testing.expectEqualStrings("[INFO] between blank lines\n", blank.stdout);
    try expectCounts(try sb.results(blank), 4, 1, 3, 1);
}

test "file: a line longer than the read buffer" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const a = sb.alloc();
    const long = try a.alloc(u8, 2_500_000);
    @memset(long, 'x');
    const junk = try a.alloc(u8, 1_200_000);
    @memset(junk, 'y');
    try sb.write("in.txt", try mem.concat(a, u8, &.{
        "2025-01-01 12:00:00 INFO before\n",
        "2025-01-01 12:00:01 WARN ",
        long,
        "\n2025-01-01 12:00:02 ERROR between\n",
        junk,
        "\n2025-01-01 12:00:03 DEBUG after\n",
    }));

    // The long lines count once each and the lines around them are intact
    for ([_][]const u8{ "1", "8" }) |threads| {
        const r = try sb.runOk(&.{ "-t", threads, "--count-only", "in.txt" });
        const res = try sb.results(r);
        try expectCounts(res, 5, 4, 1, 4);
        try expectLevels(res, 1, 1, 1, 1);
    }
    const r = try sb.runOk(&.{ "-t", "1", "-o", "raw", "in.txt" });
    try testing.expectEqualStrings("[INFO] before\n[WARN] " ++ "x" ** 255 ++ "\n[ERROR] between\n[DEBUG] after\n", r.stdout);
}

test "several files are read in order" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("a.txt", "2025-01-01 12:00:00 INFO a one\nnot a log line\n");
    // No newline at the end: must not run into the next file's first line
    try sb.write("b.txt", "2025-01-01 12:00:01 WARN b one");
    try sb.write("c.txt", "2025-01-01 12:00:02 ERROR c one\n2025-01-01 12:00:03 DEBUG c two\n");

    const r = try sb.runOk(&.{ "-t", "1", "-o", "raw", "a.txt", "b.txt", "c.txt" });
    try testing.expectEqualStrings("[INFO] a one\n[WARN] b one\n[ERROR] c one\n[DEBUG] c two\n", r.stdout);
    const res = try sb.results(r);
    try testing.expectEqual(@as(?u64, 3), res.files);
    try expectCounts(res, 5, 4, 1, 4);
    try expectLevels(res, 1, 1, 1, 1);
}

test "a missing file among good ones: warning, exit status 1, the rest is processed" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("a.txt", "2025-01-01 12:00:00 INFO a one\n");
    try sb.write("c.txt", "2025-01-01 12:00:02 ERROR c one\n");

    const r = try sb.run(&.{ "-t", "1", "-o", "raw", "a.txt", "missing.txt", "c.txt" });
    try expectExit(1, r);
    try testing.expect(contains(r.stderr, "Warning: cannot open missing.txt\n"));
    try testing.expectEqualStrings("[INFO] a one\n[ERROR] c one\n", r.stdout);
    try expectCounts(try sb.results(r), 2, 2, 0, 2);

    // Opening a directory works, reading it does not
    try sb.tmp.dir.makeDir("folder");
    const dir = try sb.run(&.{ "-t", "1", "-o", "raw", "folder", "c.txt" });
    try expectExit(1, dir);
    try testing.expect(contains(dir.stderr, "Warning: cannot ") and contains(dir.stderr, " folder\n"));
    try testing.expectEqualStrings("[ERROR] c one\n", dir.stdout);
    try expectCounts(try sb.results(dir), 1, 1, 0, 1);

    // Nothing readable at all
    const none = try sb.run(&.{ "--count-only", "missing.txt" });
    try expectExit(1, none);
    try testing.expect(contains(none.stderr, "Warning: cannot open missing.txt\n"));
    try expectCounts(try sb.results(none), 0, 0, 0, 0);
}

test "more than 256 input files" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("sample.txt", sample);
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(sb.alloc(), &.{ "-t", "2", "--count-only" });
    try args.appendNTimes(sb.alloc(), "sample.txt", 300);

    const r = try sb.runOk(args.items);
    const res = try sb.results(r);
    try testing.expectEqual(@as(?u64, 300), res.files);
    try expectCounts(res, 300 * 6, 300 * 5, 300, 300 * 5);
}

test "a FIFO is read to its end" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("sample.txt", sample);
    const r = try sb.sh(
        \\mkfifo in.fifo || exit 2
        \\cat sample.txt > in.fifo &
        \\"$1" -t 1 -o raw in.fifo
        \\status=$?
        \\kill $! 2> /dev/null
        \\wait
        \\exit $status
    );
    try expectExit(0, r);
    try testing.expectEqualStrings(sample_raw, r.stdout);
    try expectCounts(try sb.results(r), 6, 5, 1, 5);
}

test "/dev/stdin fed by a pipe is read to its end" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    // More than a pipe holds at a time, so its reported size is never the whole input
    const gen = try sb.generate("20K", "gen.txt", &.{});
    const r = try sb.sh(
        \\cat gen.txt | "$1" -t 2 --count-only /dev/stdin
    );
    try expectExit(0, r);
    try expectCounts(try sb.results(r), gen.total, gen.valid, gen.invalid, gen.valid);
}

test "a lone '-' reads stdin, in its place among the files" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("a.txt", "2025-01-01 12:00:00 INFO from a\n");
    try sb.write("c.txt", "2025-01-01 12:00:02 ERROR from c\n");

    const r = try sb.runInput(&.{ "-t", "1", "-o", "raw", "a.txt", "-", "c.txt" }, "2025-01-01 12:00:01 WARN from stdin\n");
    try expectExit(0, r);
    try testing.expectEqualStrings("[INFO] from a\n[WARN] from stdin\n[ERROR] from c\n", r.stdout);
    const res = try sb.results(r);
    try testing.expectEqual(@as(?u64, 3), res.files);
    try expectCounts(res, 3, 3, 0, 3);
}

test "stdin: large piped input, one thread, record output" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const gen = try sb.generate("6M", "big.txt", &.{});

    // cat delivers much faster than one worker can format, so the queue
    // between reader and worker is full for most of the run
    const r = try sb.sh(
        \\{ cat big.txt | "$1" -t 1 -o jsonl; echo "logproc exit status: $?" >&2; } | wc -l
    );
    try expectExit(0, r);
    const label = "logproc exit status: ";
    const at = mem.lastIndexOf(u8, r.stderr, label) orelse return error.NoExitStatus;
    try testing.expectEqualStrings("0", mem.sliceTo(r.stderr[at + label.len ..], '\n'));
    try expectCounts(try sb.results(r), gen.total, gen.valid, gen.invalid, gen.valid);
    // Every record was written exactly once
    try testing.expectEqual(@as(?u64, gen.valid), parseCount(mem.trim(u8, r.stdout, " \n")));
}

test "memory: peak use stays far below the size of a large input" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const gen = try sb.generate("6M", "big.txt", &.{});
    const size = (try sb.tmp.dir.statFile("big.txt")).size;

    // Whatever the reader has read ahead of the workers must not pile up
    for ([_][]const []const u8{
        &.{ "-t", "8", "--count-only", "big.txt" },
        &.{ "-t", "1", "-o", "jsonl", "-O", "/dev/null", "big.txt" },
    }) |args| {
        errdefer printArgs(args);
        const r = try sb.runOk(args);
        try expectCounts(try sb.results(r), gen.total, gen.valid, gen.invalid, gen.valid);
        const max_rss = r.max_rss orelse return error.SkipZigTest;
        errdefer std.debug.print("\npeak memory: {d} bytes, input: {d} bytes\n", .{ max_rss, size });
        try testing.expect(max_rss < size / 4);
    }
}

// ============================================================================
// TEST SUITE: Command Line
// ============================================================================

// True if the help text has an entry for `option`: an indented line that
// starts with the option names
fn helpLists(help: []const u8, option: []const u8) bool {
    var lines = mem.splitScalar(u8, help, '\n');
    while (lines.next()) |line| {
        if (!mem.startsWith(u8, line, "  -")) continue;
        var words = mem.tokenizeAny(u8, line, ", ");
        while (words.next()) |word| {
            if (word[0] != '-') break;
            if (mem.eql(u8, word, option)) return true;
        }
    }
    return false;
}

test "help lists every option and exits with status 0" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const long = try sb.runOk(&.{"--help"});
    try testing.expectEqualStrings("", long.stdout);
    try testing.expect(mem.startsWith(u8, long.stderr, "Usage: logproc "));
    for ([_][]const u8{
        "-t",               "-l",      "-m",           "--after", "--before", "-o",       "-O",
        "--split-by-level", "--stats", "--count-only", "-f",      "--follow", "--config", "-h",
        "--help",           "--",
    }) |option| {
        errdefer std.debug.print("\nno help entry for {s}\n", .{option});
        try testing.expect(helpLists(long.stderr, option));
    }
    // The values an option takes
    for ([_][]const u8{ "json", "jsonl", "csv", "tsv", "raw", "hourly", "daily", "minute", "by-level", "DEBUG,INFO,WARN,ERROR", "YYYY-MM-DD", "stdin" }) |word| {
        errdefer std.debug.print("\nhelp does not mention {s}\n", .{word});
        try testing.expect(contains(long.stderr, word));
    }

    // -h is the same, also next to other arguments
    const short = try sb.runOk(&.{ "-o", "raw", "-h", "missing.txt" });
    try testing.expectEqualStrings("", short.stdout);
    try testing.expectEqualStrings(long.stderr, short.stderr);
}

test "an unknown option is an error" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("sample.txt", sample);
    for ([_][]const u8{ "--bogus", "-x", "--count-onl", "-ojson", "--stats=daily", "-T" }) |option| {
        errdefer std.debug.print("\noption: {s}\n", .{option});
        const line = try expectUsageError(try sb.run(&.{ "-o", "raw", option, "sample.txt" }));
        try testing.expect(contains(line, option));
        // Wherever it stands
        _ = try expectUsageError(try sb.run(&.{ "sample.txt", option }));
    }
}

test "an option without its value is an error" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("sample.txt", sample);
    for ([_][]const u8{ "-t", "-l", "-m", "-o", "-O", "--stats", "--after", "--before", "--config" }) |option| {
        errdefer std.debug.print("\noption: {s}\n", .{option});
        const line = try expectUsageError(try sb.run(&.{ "sample.txt", option }));
        try testing.expect(contains(line, option));
    }
}

test "-t: needs an integer, values outside 1..12 are clamped" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    for ([_][]const u8{ "abc", "4x", "2.5", "0x10", "" }) |value| {
        errdefer std.debug.print("\n-t '{s}'\n", .{value});
        _ = try expectUsageError(try sb.runInput(&.{ "-t", value, "--count-only" }, sample));
    }
    // The stdin banner names the thread count in use
    for ([_]struct { value: []const u8, banner: []const u8 }{
        .{ .value = "3", .banner = " 3 threads" },
        .{ .value = "12", .banner = " 12 threads" },
        .{ .value = "0", .banner = " 1 threads" },
        .{ .value = "-5", .banner = " 1 threads" },
        .{ .value = "99", .banner = " 12 threads" },
    }) |case| {
        errdefer std.debug.print("\n-t {s}\n", .{case.value});
        const r = try sb.runInput(&.{ "-t", case.value, "--count-only" }, sample);
        try expectExit(0, r);
        try testing.expect(contains(r.stderr, case.banner));
        try expectCounts(try sb.results(r), 6, 5, 1, 5);
    }
}

test "-o: an unknown format is an error" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("sample.txt", sample);
    for ([_][]const u8{ "xml", "yaml", "jsonlines", "" }) |format| {
        errdefer std.debug.print("\n-o '{s}'\n", .{format});
        _ = try expectUsageError(try sb.run(&.{ "-o", format, "sample.txt" }));
    }
}

test "--stats: an unknown mode is an error" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("sample.txt", sample);
    for ([_][]const u8{ "weekly", "hour", "bylevel", "" }) |mode| {
        errdefer std.debug.print("\n--stats '{s}'\n", .{mode});
        _ = try expectUsageError(try sb.run(&.{ "--stats", mode, "sample.txt" }));
    }
}

test "'--' ends the options" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("sample.txt", sample);
    try sb.write("-dash.txt", "2025-01-01 12:00:00 INFO from a file named like an option\n");

    const dash = try sb.runOk(&.{ "-t", "1", "-o", "raw", "--", "-dash.txt", "sample.txt" });
    try testing.expectEqualStrings("[INFO] from a file named like an option\n" ++ sample_raw, dash.stdout);
    try testing.expect(!contains(dash.stderr, "Warning"));
    const res = try sb.results(dash);
    try testing.expectEqual(@as(?u64, 2), res.files);
    try expectCounts(res, 7, 6, 1, 6);

    // What follows is a file name even if it looks like an option
    const r = try sb.run(&.{ "-t", "1", "-o", "raw", "--", "sample.txt", "--count-only" });
    try expectExit(1, r);
    try testing.expect(contains(r.stderr, "Warning: cannot open --count-only\n"));
    try testing.expectEqualStrings(sample_raw, r.stdout);
}

test "a usage error leaves the output files alone" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("sample.txt", sample);
    try sb.write("bad.conf", "format = xml\n");
    try sb.write("out.txt", "precious\n");

    for ([_][]const []const u8{
        &.{ "-O", "out.txt", "-l", "FATAL", "sample.txt" },
        &.{ "-O", "out.txt", "sample.txt", "--bogus" },
        &.{ "-O", "out.txt", "sample.txt", "-t" },
        &.{ "-O", "out.txt", "-t", "many", "sample.txt" },
        &.{ "-O", "out.txt", "-o", "xml", "sample.txt" },
        &.{ "-O", "out.txt", "--stats", "weekly", "sample.txt" },
        &.{ "-O", "out.txt", "--after", "2025-02-30", "sample.txt" },
        &.{ "-O", "out.txt", "--after", "2025-01-02", "--before", "2025-01-01", "sample.txt" },
        &.{ "-O", "out.txt", "--config", "missing.conf", "sample.txt" },
        &.{ "-O", "out.txt", "--config", "bad.conf", "sample.txt" },
        &.{ "--split-by-level", "-O", "new.txt", "-l", "FATAL", "sample.txt" },
        &.{ "--split-by-level", "--after", "2025-01-02", "--before", "2025-01-01", "sample.txt" },
        &.{ "--split-by-level", "--config", "bad.conf", "sample.txt" },
        &.{ "--split-by-level", "--config", "missing.conf", "sample.txt" },
    }) |args| {
        errdefer printArgs(args);
        _ = try expectUsageError(try sb.run(args));
        try testing.expectEqualStrings("precious\n", try sb.read("out.txt"));
        for ([_][]const u8{ "new.txt", "debug.txt", "info.txt", "warn.txt", "error.txt" }) |name| {
            try testing.expect(!sb.exists(name));
        }
    }
}

test "the Results block" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("sample.txt", sample);

    const r = try sb.runOk(&.{ "-o", "raw", "sample.txt" });
    const at = mem.indexOf(u8, r.stderr, "=== Results ===\n") orelse return error.NoResultsBlock;
    const expected =
        \\=== Results ===
        \\Total:   6
        \\Valid:   5
        \\Invalid: 1
        \\Matched: 5
        \\--- By Level ---
        \\DEBUG:   1
        \\INFO:    1
        \\WARN:    1
        \\ERROR:   2
        \\--- Performance ---
        \\
    ++ "Time:    ";
    try testing.expectStringStartsWith(r.stderr[at..], expected);
    // 'Time:    0.00 sec'
    var rest = mem.splitScalar(u8, r.stderr[at + expected.len ..], '\n');
    var words = mem.splitScalar(u8, rest.first(), ' ');
    _ = try std.fmt.parseFloat(f64, words.first());
    try testing.expectEqualStrings("sec", words.rest());
}

test "--count-only and --stats write nothing to stdout" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("sample.txt", sample);
    for ([_][]const []const u8{
        &.{"--count-only"},
        &.{ "--count-only", "-o", "json" },
        &.{ "--count-only", "-o", "csv" },
        &.{ "--stats", "daily" },
        &.{ "--stats", "by-level", "-o", "json" },
        &.{ "--stats", "hourly", "--count-only" },
    }) |args| {
        errdefer printArgs(args);
        const r = try sb.runOk(try mem.concat(sb.alloc(), []const u8, &.{ args, &.{"sample.txt"} }));
        try testing.expectEqualStrings("", r.stdout);
        try expectCounts(try sb.results(r), 6, 5, 1, 5);
    }
}

test "a failed write of the output gives exit status 1" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("sample.txt", sample);
    // stdout is closed, so the records cannot be written
    const r = try sb.sh(
        \\"$1" -t 1 -o raw sample.txt >&-
    );
    try expectExit(1, r);
    try testing.expect(mem.startsWith(u8, r.stderr, "Error: ") or contains(r.stderr, "\nError: "));
    try expectCounts(try sb.results(r), 6, 5, 1, 5);
}

test "a reader that leaves early ends the run without an error message" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    // More output than a pipe holds, so logproc is still writing when head leaves
    const gen = try sb.generate("20K", "gen.txt", &.{});
    const quiet = try sb.sh(
        \\{ "$1" -t 1 -o jsonl gen.txt 2> quiet.err; echo "status $?" > quiet.status; } | head -n 1
    );
    try expectExit(0, quiet);
    try testing.expectEqual(1, (try parseJsonLines(sb.alloc(), quiet.stdout)).len);
    // SIGPIPE ends logproc like any other filter (128 + 13), and that is no
    // failure to report
    try testing.expectEqualStrings("status 141\n", try sb.read("quiet.status"));
    const quiet_stderr = try sb.read("quiet.err");
    try testing.expect(!contains(quiet_stderr, "Error"));
    try testing.expect(!contains(quiet_stderr, "=== Results ==="));

    // With SIGPIPE ignored the run goes on to its end, and the records that
    // could not be written are a failure
    const ignored = try sb.sh(
        \\trap '' PIPE
        \\{ "$1" -t 1 -o jsonl gen.txt 2> ignored.err; echo "status $?" > ignored.status; } | head -n 1
    );
    try expectExit(0, ignored);
    try testing.expectEqualStrings("status 1\n", try sb.read("ignored.status"));
    const stderr = try sb.read("ignored.err");
    try testing.expectEqual(1, mem.count(u8, stderr, "Error: "));
    try expectCounts(try parseResults(sb.alloc(), stderr), gen.total, gen.valid, gen.invalid, gen.valid);
}

// ============================================================================
// TEST SUITE: Config File
// ============================================================================

test "config: every key" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("sample.txt", sample);

    for ([_]struct { config: []const u8, records: []const u8 }{
        .{ .config = "levels = ERROR\n", .records = raw_timeout ++ raw_failure },
        .{ .config = "levels = warn,debug\n", .records = raw_debug ++ raw_warn },
        .{ .config = "pattern = timeout\n", .records = raw_timeout },
        .{ .config = "pattern =\n", .records = sample_raw }, // Empty: no message filter
        .{ .config = "after = 2025-01-02 12:00:00\n", .records = raw_timeout ++ raw_failure },
        .{ .config = "before = 2025-01-01\n", .records = raw_debug },
        .{ .config = "after = 2025-01-01 12:00:00\nbefore = 2025-01-02\n", .records = raw_info ++ raw_warn },
    }) |case| {
        errdefer std.debug.print("\nconfig:\n{s}", .{case.config});
        try sb.write("test.conf", case.config);
        const r = try sb.runOk(&.{ "--config", "test.conf", "-t", "1", "-o", "raw", "sample.txt" });
        try testing.expectEqualStrings(case.records, r.stdout);
    }

    try sb.write("test.conf", "format = tsv\n");
    const tsv = try sb.runOk(&.{ "--config", "test.conf", "-l", "INFO", "sample.txt" });
    try testing.expectEqualStrings("level\ttimestamp\tmessage\nINFO\t1735732800\tUser logged in\n", tsv.stdout);

    try sb.write("test.conf", "format = jsonl\n");
    const jsonl = try sb.runOk(&.{ "--config", "test.conf", "-t", "1", "sample.txt" });
    try testing.expectEqualStrings(sample_jsonl, jsonl.stdout);

    try sb.write("test.conf", "stats = daily\n");
    const daily = try sb.runOk(&.{ "--config", "test.conf", "sample.txt" });
    try testing.expectEqualStrings("", daily.stdout);
    try expectStats(try sb.results(daily), "Daily",
        \\2025-01-01  D:1 I:1 W:0 E:0 (total:2)
        \\2025-01-02  D:0 I:0 W:1 E:1 (total:2)
        \\2025-01-03  D:0 I:0 W:0 E:1 (total:1)
    );

    try sb.write("test.conf", "threads = 3\n");
    const threads = try sb.runInput(&.{ "--config", "test.conf", "--count-only" }, sample);
    try expectExit(0, threads);
    try testing.expect(contains(threads.stderr, " 3 threads"));
    try expectCounts(try sb.results(threads), 6, 5, 1, 5);
}

test "config: blanks, CRLF, comments and empty lines" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("sample.txt", sample);
    try sb.write("test.conf", "# settings for the test\r\n" ++
        "\r\n" ++
        "  levels = warn,ERROR  \r\n" ++
        "format=csv\r\n" ++
        "\t pattern\t=\tdisk\r\n" ++
        "   \r\n" ++
        "after = 2025-01-02\r\n" ++
        "before = 2025-01-02 23:59:59\r\n" ++
        "#levels = DEBUG\r\n" ++
        "   # an indented comment\r\n" ++
        "\t#format = raw\r\n" ++
        "threads = 1\r\n");

    const r = try sb.runOk(&.{ "--config", "test.conf", "sample.txt" });
    try testing.expectEqualStrings("level,timestamp,message\nWARN,1735776000,\"Disk almost full\"\n", r.stdout);
    try expectCounts(try sb.results(r), 6, 5, 1, 1);
}

test "config: the command line wins, whatever the argument order" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("sample.txt", sample);
    // On its own this config selects nothing the command line below selects
    try sb.write("test.conf", "levels=DEBUG\n" ++
        "format=csv\n" ++
        "pattern=cache\n" ++
        "after=2025-01-04\n" ++
        "before=2025-01-01\n" ++
        "threads=2\n");
    const options = [_][]const u8{ "-l", "ERROR", "-o", "raw", "-m", "disk", "--after", "2025-01-01", "--before", "2025-01-05", "-t", "5" };
    const config = [_][]const u8{ "--config", "test.conf" };

    for ([_][]const []const u8{ &(config ++ options), &(options ++ config) }) |args| {
        errdefer printArgs(args);
        const r = try sb.runInput(args, sample);
        try expectExit(0, r);
        try testing.expectEqualStrings(raw_failure, r.stdout);
        try testing.expect(contains(r.stderr, " 5 threads"));
        try expectCounts(try sb.results(r), 6, 5, 1, 1);
    }

    // An empty -m takes the config's pattern away, and --stats replaces its mode
    try sb.write("test.conf", "pattern=cache\nstats=daily\n");
    for ([_][]const []const u8{
        &.{ "--config", "test.conf", "-m", "", "--stats", "by-level", "sample.txt" },
        &.{ "-m", "", "--stats", "by-level", "sample.txt", "--config", "test.conf" },
    }) |args| {
        errdefer printArgs(args);
        const res = try sb.results(try sb.runOk(args));
        try expectStats(res, "By Level",
            \\DEBUG : 1
            \\INFO  : 1
            \\WARN  : 1
            \\ERROR : 2
        );
        try expectCounts(res, 6, 5, 1, 5);
    }
}

// A config file that must be refused, with the number of the offending line
fn expectConfigError(sb: *Sandbox, config: []const u8, line_number: u64) !void {
    errdefer std.debug.print("\nconfig:\n{s}\n", .{config});
    try sb.write("test.conf", config);
    const line = try expectUsageError(try sb.run(&.{ "--config", "test.conf", "-o", "raw", "sample.txt" }));
    try testing.expect(mentionsNumber(line, line_number));
}

test "config: an unknown key is an error that names the line" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("sample.txt", sample);
    try expectConfigError(&sb, "# settings\nlevels = ERROR\n\ncolour = blue\nformat = csv\n", 4);
    try expectConfigError(&sb, "level = ERROR\n", 1);
    try expectConfigError(&sb, "format = csv\nformats = csv\n", 2);
    try expectConfigError(&sb, "format = csv\n\n\njust some words\n", 4);
}

test "config: an invalid value is an error that names the line" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("sample.txt", sample);
    try expectConfigError(&sb, "format = xml\n", 1);
    try expectConfigError(&sb, "format = csv\nlevels = ERROR,FATAL\n", 2);
    try expectConfigError(&sb, "\n\nlevels =\n", 3);
    try expectConfigError(&sb, "# one\n# two\n# three\nthreads = many\n", 4);
    try expectConfigError(&sb, "format = raw\r\nstats = weekly\r\n", 2);
    try expectConfigError(&sb, "\n\n\n\n\n\nafter = 2025-02-30\n", 7);
    try expectConfigError(&sb, "\n\n\n\n\n\n\n\nbefore = 2025-01-01 25:00:00\n", 9);
    try expectConfigError(&sb, "levels = ERR\n", 1);
    try expectConfigError(&sb, "format = csv\nafter = 1900-02-29\n", 2);
    try expectConfigError(&sb, "before = 2025-04-31\n", 1);

    // Each value is fine, but together they select nothing
    try sb.write("test.conf", "after = 2025-01-02\nbefore = 2025-01-01\n");
    _ = try expectUsageError(try sb.run(&.{ "--config", "test.conf", "sample.txt" }));
}

test "config: an unreadable file is an error" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("sample.txt", sample);
    _ = try expectUsageError(try sb.run(&.{ "--config", "missing.conf", "-o", "raw", "sample.txt" }));
    _ = try expectUsageError(try sb.run(&.{ "-o", "raw", "sample.txt", "--config", "missing.conf" }));
}

test "config: a second --config is an error" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("sample.txt", sample);
    try sb.write("one.conf", "levels = ERROR\n");
    try sb.write("two.conf", "format = raw\n");
    for ([_][]const []const u8{
        &.{ "--config", "one.conf", "--config", "two.conf", "sample.txt" },
        &.{ "--config", "one.conf", "sample.txt", "--config", "one.conf" },
        // A first file that would be skipped unread is no better
        &.{ "--config", "missing.conf", "--config", "two.conf", "sample.txt" },
    }) |args| {
        errdefer printArgs(args);
        const line = try expectUsageError(try sb.run(args));
        try testing.expect(contains(line, "--config"));
        try testing.expect(contains(line, "more than once"));
    }
}

// ============================================================================
// TEST SUITE: Follow Mode
// ============================================================================

test "follow: appended lines are delivered; SIGINT prints the results" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("old.txt", "2025-01-01 12:00:00 INFO from the first file\n");
    try sb.write("app.log", "2025-01-01 12:00:01 WARN already there\n");

    // Only the last file is followed; what the files hold comes first. The
    // banner on stderr says that this is done and the file is being watched.
    var proc = try sb.spawn(&.{ "-f", "-t", "1", "-o", "raw", "old.txt", "app.log" }, false);
    defer proc.deinit();
    try proc.waitFor(.stderr, "Following app.log");
    try proc.expectStdout("[INFO] from the first file\n[WARN] already there\n");

    try sb.append("app.log", "2025-01-01 12:00:02 ERROR appended\nnot a log line\n");
    try proc.expectStdout("[INFO] from the first file\n[WARN] already there\n[ERROR] appended\n");
    try sb.append("app.log", "2025-01-01 12:00:03 DEBUG appended later\n");
    const records = "[INFO] from the first file\n[WARN] already there\n[ERROR] appended\n[DEBUG] appended later\n";
    try proc.expectStdout(records);

    // SIGINT ends the run in the normal way
    try proc.signal(posix.SIG.INT);
    const r = try proc.finish(&sb, wait_timeout_ms);
    try expectExit(0, r);
    try testing.expectEqualStrings(records, r.stdout);
    const res = try sb.results(r);
    try testing.expectEqual(@as(?u64, 2), res.files);
    try expectCounts(res, 5, 4, 1, 4);
    try expectLevels(res, 1, 1, 1, 1);
}

test "follow: a signal during an earlier input also ends the run with the results" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("app.log", "2025-01-01 12:00:09 ERROR never reached\n");
    for ([_]u8{ posix.SIG.INT, posix.SIG.TERM }) |sig| {
        errdefer std.debug.print("\nsignal {d}\n", .{sig});
        // stdin comes first and stays open, so the followed file is not reached
        var proc = try sb.spawn(&.{ "-f", "-t", "1", "-o", "raw", "-", "app.log" }, true);
        defer proc.deinit();
        try proc.send("2025-01-01 12:00:00 INFO first\nnot a log line\n2025-01-01 12:00:01 WARN second\n2025-01-01 12:00:02 ERROR cut o");
        try proc.expectStdout("[INFO] first\n[WARN] second\n");

        try proc.signal(sig);
        const r = try proc.finish(&sb, wait_timeout_ms);
        try expectExit(0, r);
        // The line that the signal cut off is not counted
        try testing.expectEqualStrings("[INFO] first\n[WARN] second\n", r.stdout);
        // The remaining files are not read
        try testing.expect(!contains(r.stderr, "app.log"));
        try expectCounts(try sb.results(r), 3, 2, 1, 2);
    }
}

test "follow: a line of any length does not stall the stream" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const a = sb.alloc();
    try sb.write("app.log", "2025-01-01 12:00:00 INFO first\n");

    var proc = try sb.spawn(&.{ "-f", "-t", "2", "-o", "raw", "app.log" }, false);
    defer proc.deinit();
    try proc.waitFor(.stderr, "Following app.log");
    var expected: std.ArrayList(u8) = .empty;
    try expected.appendSlice(a, "[INFO] first\n");
    try proc.expectStdout(expected.items);

    // Longer than a few KB, longer than 64 KB, longer than any read buffer:
    // the message is cut at 255 bytes as usual and the next line comes through
    for ([_]usize{ 5_000, 100_000, 3_000_000 }) |len| {
        errdefer std.debug.print("\nline length: {d}\n", .{len});
        const long = try a.alloc(u8, len);
        @memset(long, 'x');
        try sb.append("app.log", try mem.concat(a, u8, &.{ "2025-01-01 12:00:01 WARN ", long, "\n" }));
        try sb.append("app.log", try std.fmt.allocPrint(a, "2025-01-01 12:00:02 ERROR after {d} bytes\n", .{len}));
        try expected.appendSlice(a, "[WARN] " ++ "x" ** 255 ++ "\n");
        try expected.print(a, "[ERROR] after {d} bytes\n", .{len});
        try proc.expectStdout(expected.items);
    }

    try proc.signal(posix.SIG.INT);
    const r = try proc.finish(&sb, wait_timeout_ms);
    try expectExit(0, r);
    try testing.expectEqualStrings(expected.items, r.stdout);
    const res = try sb.results(r);
    try expectCounts(res, 7, 7, 0, 7);
    try expectLevels(res, 0, 1, 3, 3);
}

test "follow: a NUL byte is data, and a line is held until its newline arrives" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    try sb.write("app.log", "");

    var proc = try sb.spawn(&.{ "-f", "-t", "1", "-o", "raw", "app.log" }, false);
    defer proc.deinit();
    try proc.waitFor(.stderr, "Following app.log");

    try sb.append("app.log", "2025-01-01 12:00:00 INFO nul\x00byte\n2025-01-01 12:00:01 WARN after the nul\n");
    try proc.expectStdout("[INFO] nul\x00byte\n[WARN] after the nul\n");

    // No newline yet: the line is not processed, however long it takes
    try sb.append("app.log", "2025-01-01 12:00:02 ERROR par");
    _ = try proc.idle(300);
    try testing.expectEqualStrings("[INFO] nul\x00byte\n[WARN] after the nul\n", proc.output(.stdout));
    try sb.append("app.log", "tial\n");
    try proc.expectStdout("[INFO] nul\x00byte\n[WARN] after the nul\n[ERROR] partial\n");

    try proc.signal(posix.SIG.INT);
    const r = try proc.finish(&sb, wait_timeout_ms);
    try expectExit(0, r);
    try expectCounts(try sb.results(r), 3, 3, 0, 3);
}

test "follow: json is written as jsonl, the output file is flushed per batch; SIGTERM prints the results" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const first =
        \\{"level":"INFO","timestamp":1735732800,"message":"first"}
        \\
    ;
    const second =
        \\{"level":"ERROR","timestamp":1735732801,"message":"second"}
        \\
    ;
    const third =
        \\{"level":"INFO","timestamp":1735732803,"message":"third"}
        \\
    ;
    try sb.write("app.log", "2025-01-01 12:00:00 INFO first\n");

    var proc = try sb.spawn(&.{ "--follow", "-t", "4", "-l", "INFO,ERROR", "-o", "json", "-O", "out.json", "app.log" }, false);
    defer proc.deinit();
    try proc.waitFor(.stderr, "Following app.log");
    try proc.expectFile(&sb, "out.json", first);

    try sb.append("app.log", "2025-01-01 12:00:01 ERROR second\n2025-01-01 12:00:02 DEBUG filtered out\nnot a log line\n");
    try proc.expectFile(&sb, "out.json", first ++ second);
    try sb.append("app.log", "2025-01-01 12:00:03 INFO third\n");
    try proc.expectFile(&sb, "out.json", first ++ second ++ third);

    try proc.signal(posix.SIG.TERM);
    const r = try proc.finish(&sb, wait_timeout_ms);
    try expectExit(0, r);
    try testing.expectEqualStrings("", r.stdout);
    // A followed file has no end, so there is no array to close
    try testing.expectEqualStrings(first ++ second ++ third, try sb.read("out.json"));
    const res = try sb.results(r);
    try expectCounts(res, 5, 4, 1, 3);
    try expectLevels(res, 1, 2, 0, 1);
    // One note says that json became jsonl
    try testing.expectEqual(1, mem.count(u8, r.stderr, "Note: "));
    try testing.expect(contains(r.stderr, "jsonl"));
}

// ============================================================================
// TEST SUITE: Threads
// ============================================================================

test "threads: -t 1 and -t 8 give the same counts and the same records" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const a = sb.alloc();
    const gen = try sb.generate("100K", "gen.txt", &.{});

    const one = try sb.runOk(&.{ "-t", "1", "-o", "jsonl", "gen.txt" });
    const one_res = try sb.results(one);
    try expectCounts(one_res, gen.total, gen.valid, gen.invalid, gen.valid);
    try testing.expectEqual(gen.valid, mem.count(u8, one.stdout, "\n"));

    for ([_][]const u8{ "2", "8", "12" }) |threads| {
        errdefer std.debug.print("\n-t {s}\n", .{threads});
        const many = try sb.runOk(&.{ "-t", threads, "-o", "jsonl", "gen.txt" });
        const many_res = try sb.results(many);
        try expectCounts(many_res, gen.total, gen.valid, gen.invalid, gen.valid);
        try testing.expectEqualSlices(u64, &one_res.levels, &many_res.levels);

        try expectSameLines(a, one.stdout, many.stdout);
    }
}

// ============================================================================
// TEST SUITE: Log Generator
// ============================================================================

test "genlog: counts, line format and date range" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    // The count suffix may be in either case
    const gen = try sb.generate("2k", "gen.txt", &.{ "--start", "2024-02-28", "--end", "2024-03-02 12:00:00" });
    try testing.expectEqual(2000, gen.total);
    try testing.expectEqual(2000, gen.valid + gen.invalid);
    // Nine lines in ten are valid, give or take
    try testing.expect(gen.valid > 1700 and gen.valid < 1900);

    const lines = try splitLines(sb.alloc(), try sb.read("gen.txt"));
    try testing.expectEqual(2000, lines.len);
    var dated: u64 = 0;
    for (lines) |line| {
        if (line.len < 20 or line[4] != '-') continue; // One of the invalid lines
        errdefer std.debug.print("\nline: {s}\n", .{line});
        dated += 1;
        // The end of the range is exclusive
        try testing.expect(!mem.lessThan(u8, line[0..19], "2024-02-28 00:00:00"));
        try testing.expect(mem.lessThan(u8, line[0..19], "2024-03-02 12:00:00"));
    }
    try testing.expectEqual(gen.valid, dated);

    // logproc accepts exactly the lines the generator calls valid
    const r = try sb.runOk(&.{ "--count-only", "gen.txt" });
    try expectCounts(try sb.results(r), 2000, gen.valid, gen.invalid, gen.valid);
}

test "genlog: output on stdout is complete" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    // Several buffers full, and a last one that is written when genlog exits.
    // The variables make the allocator (macOS, glibc) overwrite freed memory,
    // so that a buffer written out after it was freed cannot go unnoticed.
    const r = try sb.sh(
        \\MallocScribble=1 MALLOC_PERTURB_=85 "$2" 300K 2> genlog.err | "$1" --count-only
    );
    try expectExit(0, r);
    const gen = try parseGenerated(try sb.read("genlog.err"));
    try testing.expectEqual(300_000, gen.total);
    try expectCounts(try sb.results(r), 300_000, gen.valid, gen.invalid, gen.valid);
}

test "genlog: the default dates lie in 2024 and 2025" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    const gen = try sb.generate("20K", "gen.txt", &.{});

    var per_year = [2]u64{ 0, 0 };
    for (try splitLines(sb.alloc(), try sb.read("gen.txt"))) |line| {
        if (line.len < 20 or line[4] != '-') continue; // One of the invalid lines
        errdefer std.debug.print("\nline: {s}\n", .{line});
        try testing.expect(!mem.lessThan(u8, line[0..19], "2024-01-01 00:00:00"));
        try testing.expect(!mem.lessThan(u8, "2025-12-28 23:59:59", line[0..19]));
        // No day after the 28th, whatever the month
        try testing.expect(!mem.lessThan(u8, "28", line[8..10]));
        per_year[line[3] - '4'] += 1;
    }
    try testing.expectEqual(gen.valid, per_year[0] + per_year[1]);
    // Both years, about half of the entries each
    for (per_year) |n| try testing.expect(n * 10 > gen.valid * 4);
}

test "genlog: K, M and B suffixes in either case" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    for ([_]struct { count: []const u8, total: u64 }{
        .{ .count = "7", .total = 7 },
        .{ .count = "3K", .total = 3_000 },
        .{ .count = "3k", .total = 3_000 },
        .{ .count = "1M", .total = 1_000_000 },
        .{ .count = "1m", .total = 1_000_000 },
    }) |case| {
        errdefer std.debug.print("\ncount: {s}\n", .{case.count});
        const gen = try sb.generate(case.count, "/dev/null", &.{});
        try testing.expectEqual(case.total, gen.total);
        try testing.expectEqual(case.total, gen.valid + gen.invalid);
    }

    // Billions are not waited for: the reader leaves after the first line,
    // and what genlog announced is enough
    for ([_]struct { count: []const u8, announced: []const u8 }{
        .{ .count = "1B", .announced = "Generating 1000000000 log entries" },
        .{ .count = "2b", .announced = "Generating 2000000000 log entries" },
    }) |case| {
        errdefer std.debug.print("\ncount: {s}\n", .{case.count});
        const r = try sb.exec(&.{ "/bin/sh", "-c", "\"$1\" \"$2\" 2> genlog.err | head -n 1", "sh", sb.genlog, case.count }, null, true);
        try expectExit(0, r);
        try testing.expectEqual(1, mem.count(u8, r.stdout, "\n"));
        try testing.expect(contains(try sb.read("genlog.err"), case.announced));
    }
}

test "genlog: bad arguments are errors" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    // `names`: what the error line has to mention
    for ([_]struct { args: []const []const u8, names: []const u8 }{
        .{ .args = &.{"abc"}, .names = "'abc'" },
        .{ .args = &.{"1G"}, .names = "'1G'" },
        .{ .args = &.{"-5"}, .names = "'-5'" },
        .{ .args = &.{"10x"}, .names = "'10x'" },
        .{ .args = &.{"1.5K"}, .names = "'1.5K'" },
        .{ .args = &.{"K"}, .names = "'K'" },
        .{ .args = &.{""}, .names = "''" },
        .{ .args = &.{ "100", "out.txt", "--start", "2025-01-01" }, .names = "--end" },
        .{ .args = &.{ "100", "out.txt", "--end", "2025-01-01" }, .names = "--start" },
        // Impossible days, in ranges that would be in order if they were accepted
        .{ .args = &.{ "100", "out.txt", "--start", "2025-02-30", "--end", "2025-04-01" }, .names = "'2025-02-30'" },
        .{ .args = &.{ "100", "out.txt", "--start", "2025-01-01", "--end", "2025-02-30" }, .names = "'2025-02-30'" },
        .{ .args = &.{ "100", "out.txt", "--start", "1900-02-29", "--end", "2025-01-01" }, .names = "'1900-02-29'" },
        .{ .args = &.{ "100", "out.txt", "--start", "2025-04-31", "--end", "2025-06-01" }, .names = "'2025-04-31'" },
        .{ .args = &.{ "100", "out.txt", "--start", "2025-00-01", "--end", "2025-06-01" }, .names = "'2025-00-01'" },
        .{ .args = &.{ "100", "out.txt", "--start", "2025-01-00", "--end", "2025-06-01" }, .names = "'2025-01-00'" },
        .{ .args = &.{ "100", "out.txt", "--start", "2025-01-01", "--end", "tomorrow" }, .names = "'tomorrow'" },
        .{ .args = &.{ "100", "out.txt", "--start", "2025-01-02", "--end", "2025-01-01" }, .names = "--end" },
        .{ .args = &.{ "100", "out.txt", "--start", "2025-01-01", "--end", "2025-01-01" }, .names = "--end" },
        .{ .args = &.{ "100", "out.txt", "--bogus" }, .names = "'--bogus'" },
        // An unknown option is not taken for the output file
        .{ .args = &.{ "100", "--bogus" }, .names = "'--bogus'" },
        .{ .args = &.{ "100", "-x", "out.txt" }, .names = "'-x'" },
        .{ .args = &.{ "100", "out.txt", "--start" }, .names = "--start" },
        .{ .args = &.{ "100", "out.txt", "extra.txt" }, .names = "'extra.txt'" },
    }) |case| {
        errdefer printArgs(case.args);
        const line = try expectUsageError(try sb.exec(try sb.command(sb.genlog, case.args), null, false));
        try testing.expect(contains(line, case.names));
        // Nothing was generated
        for ([_][]const u8{ "out.txt", "extra.txt", "--bogus", "-x" }) |name| {
            try testing.expect(!sb.exists(name));
        }
    }
    for (past_month_ends) |date| {
        errdefer std.debug.print("\n--end {s}\n", .{date});
        const line = try expectUsageError(try sb.exec(try sb.command(sb.genlog, &.{ "100", "out.txt", "--start", "2024-01-01", "--end", date }), null, false));
        try testing.expect(contains(line, date));
        try testing.expect(!sb.exists("out.txt"));
    }
}

test "genlog: leap days and month ends are accepted as --start and --end" {
    var sb = try Sandbox.init();
    defer sb.deinit();
    for (month_ends) |date| {
        errdefer std.debug.print("\n--end {s}\n", .{date});
        const gen = try sb.generate("50", "gen.txt", &.{ "--start", "2025-01-01", "--end", date });
        try testing.expectEqual(50, gen.total);
    }
    for ([_]struct { start: []const u8, end: []const u8 }{
        .{ .start = "2024-02-29", .end = "2024-03-01" },
        .{ .start = "2000-02-29 00:00:00", .end = "2000-02-29 00:00:10" },
        .{ .start = "2025-04-30", .end = "2025-05-31 23:59:59" },
        .{ .start = "2025-12-31", .end = "2026-01-01" },
    }) |case| {
        errdefer std.debug.print("\n--start '{s}' --end '{s}'\n", .{ case.start, case.end });
        const gen = try sb.generate("500", "gen.txt", &.{ "--start", case.start, "--end", case.end });
        var dated: u64 = 0;
        for (try splitLines(sb.alloc(), try sb.read("gen.txt"))) |line| {
            if (line.len < 20 or line[4] != '-') continue; // One of the invalid lines
            dated += 1;
            try testing.expect(!mem.lessThan(u8, line[0..case.start.len], case.start));
            try testing.expect(mem.lessThan(u8, line[0..case.end.len], case.end));
        }
        try testing.expectEqual(gen.valid, dated);
        // The dates are real: logproc accepts every one of these lines
        const r = try sb.runOk(&.{ "--count-only", "gen.txt" });
        try expectCounts(try sb.results(r), 500, gen.valid, gen.invalid, gen.valid);
    }
}
