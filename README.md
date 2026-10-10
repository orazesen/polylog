# polylog

A high-throughput multi-language log processor: one binary, linked from C, Zig, Rust and C++, that validates, filters, aggregates and re-formats log lines. The published benchmark below shows **3.3 GB/s** with 8 threads.

## Architecture

```
C (reader) → Zig (parser) → Rust (processor) → C++ (formatter)
```

| Component       | Language | Role                                           |
| --------------- | -------- | ---------------------------------------------- |
| `reader.c`      | C        | CLI, file I/O, worker threads, statistics      |
| `parser.zig`    | Zig      | Log line parsing, validation                   |
| `processor.rs`  | Rust     | Filtering (level, time range, message)         |
| `formatter.cpp` | C++      | Output formatting (JSON, JSONL, CSV, TSV, raw) |

The four are compiled to object files and linked into one binary; they pass a shared `struct LogEntry` (`logentry.h`) across the C ABI.

## Performance

Benchmarked on Apple M2 Pro with 500M log entries (~22 GB):

| Method                  | Speed          |
| ----------------------- | -------------- |
| `dd` read of the file   | 3,328 MB/s     |
| **polylog (8 threads)** | **3,327 MB/s** |
| polylog (1 thread)      | 529 MB/s       |

`make benchmark` runs this comparison: it writes the file with `genlog`, reads it once with `dd bs=1M`, then runs `logproc --count-only` on it (parsing and filtering, no record output) and prints the time and speed that logproc reports. Both reads follow directly after the file is written, so much of it can be served from the page cache instead of the disk. The figures predate the current revision of the code and have not been re-measured.

## Requirements

- **clang** (C and C++ compiler)
- **zig** 0.15 (tested with 0.15.2)
- **rustc** 1.82 or newer (tested with 1.98)
- **make**

The integration tests also need a POSIX `/bin/sh` with `cat`, `wc` and `mkfifo`, and about 300 MB of free disk space. `make benchmark` needs `python3`, `bc`, `dd` and `awk`.

Developed and tested on macOS on Apple Silicon (arm64) only. The reader scans for newlines with NEON where it is available and falls back to `memchr` elsewhere. The C, C++ and Zig sources also compile for x86-64 macOS, but that is a compile check: nothing other than the arm64 build has been run.

## Quick Start

```bash
# Build
make

# Generate test logs (about 10% of the lines are invalid on purpose)
./output/genlog 100K logs.txt

# Validate and count
./output/logproc --count-only logs.txt

# Write the ERROR entries as JSON Lines
./output/logproc -l ERROR -o jsonl logs.txt > errors.jsonl

# Run all tests
make test-all

# Run a small benchmark (the default size, 500M lines, needs about 22 GB of disk)
make benchmark BENCH_SIZE=10M
```

## Usage

```
Usage: logproc [OPTIONS] [FILE...]

Reads the FILEs in order; '-' or no FILE at all means stdin.
Lines look like 'YYYY-MM-DD HH:MM:SS LEVEL message' (times are UTC).

Options:
  -t N             Use N threads (default: 8; clamped to 1..12)
  -l LEVELS        Filter by level: comma-separated DEBUG,INFO,WARN,ERROR
                   (any case)
  -m PATTERN       Filter messages containing PATTERN (ignoring case);
                   an empty PATTERN means no filter
  --after DATE     Only logs at or after DATE: YYYY-MM-DD (midnight)
                   or 'YYYY-MM-DD HH:MM:SS'
  --before DATE    Only logs at or before DATE
  -o FORMAT        Output format: json (default, one array), jsonl, csv,
                   tsv, raw
  -O FILE          Write output to FILE instead of stdout
  --split-by-level Write separate files: debug.txt, info.txt, etc.
  --stats MODE     Aggregate the matching logs instead of writing them:
                   hourly, daily, minute, by-level
  --count-only     Skip output, only count
  -f, --follow     Follow the last FILE for new lines (like tail -f);
                   Ctrl+C stops and prints the results; json output
                   becomes jsonl
  --config FILE    Load settings from FILE: lines 'key = value' with the
                   keys levels, format, pattern, stats, after, before,
                   threads; '#' starts a comment line. Options given on
                   the command line win. One config file at most
  -h, --help       Show this help
  --               End of options: the rest are FILEs

Exit status: 0 on success; 1 for a usage or config error, or when an
input could not be read or the output could not be written.
```

Records go to stdout (or to `-O FILE`); progress messages, warnings and the results go to stderr.

- **Inputs.** Files, pipes, FIFOs and process substitutions are read to their end. An input that cannot be opened prints `Warning: cannot open PATH`; the other inputs are still processed and the exit status is 1.
- **Output.** Records are written in blocks of 64 KB and whenever the workers have caught up with the input, so behind a slow producer (`tail -f app.log | logproc -o raw`) each record appears as soon as its line is complete. When the reader of the output goes away early (`logproc ... | head`), SIGPIPE ends the run without a message, as it ends any filter; if SIGPIPE is ignored, the run finishes, reports `Error: write failed, output is incomplete` and exits with status 1, as for any other failed write.
- **Errors.** An unknown option, a missing or invalid value, or a bad config file prints one line starting with `Error: ` and exits with status 1 before any input is read or any output file is created.
- **Filters.** An entry must pass every filter given. `-l` also accepts lowercase names (`-l error,warn`); an unknown name is an error. `-m` is a substring match that ignores ASCII case.
- **`--after` / `--before`** are inclusive at both ends: an entry passes when after <= its time <= before. A value is exactly `YYYY-MM-DD` or `YYYY-MM-DD HH:MM:SS` and must be a real calendar date. A date alone means 00:00:00, so `--before 2025-01-31` leaves out the rest of that day; write `--before '2025-01-31 23:59:59'` to include it. `--after` later than `--before` is an error.
- **`--split-by-level`** writes raw lines to `debug.txt`, `info.txt`, `warn.txt` and `error.txt` in the current directory, whatever `-o` says, and nothing to stdout.

### Config file

```
# errors.conf: warnings and errors about timeouts in January 2025
levels  = WARN,ERROR
pattern = timeout
after   = 2025-01-01
before  = 2025-01-31 23:59:59
format  = csv
threads = 4
```

One `key = value` per line. Blanks around keys and values and CRLF line endings are ignored; empty lines and lines whose first non-blank character is `#` are skipped. The keys `levels`, `format`, `pattern`, `stats`, `after`, `before` and `threads` take the same values as `-l`, `-o`, `-m`, `--stats`, `--after`, `--before` and `-t`; the other options have no key. An unknown key or an invalid value is an error that names the line (`Error: errors.conf:3: unknown key 'colour'`). Options given on the command line override the file, wherever `--config` stands among them. `--config` may be given once; a second one is an error.

## Examples

```bash
# ERROR entries as one JSON array
./output/logproc -l ERROR logs.txt

# WARN and ERROR entries that mention "timeout", as JSON Lines in a file
./output/logproc -o jsonl -l WARN,ERROR -m timeout -O timeouts.jsonl logs.txt

# January 2025 as CSV
./output/logproc -o csv --after 2025-01-01 --before '2025-01-31 23:59:59' logs.txt

# Hourly statistics
./output/logproc --stats hourly logs.txt

# Split output by log level
./output/logproc --split-by-level logs.txt

# Read a pipe, keep the input order
gzip -dc logs.txt.gz | ./output/logproc -t 1 -o raw

# Watch a growing file
./output/logproc -f -l WARN,ERROR -o raw app.log
```

## Log Format

```
2025-01-01 12:00:00 INFO User logged in
2025-01-01 12:00:01 ERROR Connection failed
```

One entry per line: `YYYY-MM-DD HH:MM:SS LEVEL message`. The parser is strict, and a line that breaks a rule is counted as invalid and skipped:

- The timestamp starts in the first column with exactly this shape and must be a real date and time: month 1-12, a day that exists in that month (`2024-02-29` is valid, `2025-02-29` is not), hour 0-23, minute and second 0-59. Any four-digit year is accepted. Times are taken as UTC.
- The level is `DEBUG`, `INFO`, `WARN` or `ERROR`, in uppercase and as a whole word: `info`, `INFOX` and `WARNING` are invalid.
- One space separates the level from the message. The message may be empty; otherwise its bytes are kept as they are.
- A line can be any length, but a message longer than 255 bytes is truncated to 255 bytes.
- CRLF line endings are tolerated: one trailing carriage return is dropped.
- An empty line counts as an invalid line.

## Output Formats

The output for the two lines above. Timestamps are Unix seconds (negative before 1970).

### JSON (default)

One array, valid as a single document; `[]` when no entry matched.

```json
[
{"level":"INFO","timestamp":1735732800,"message":"User logged in"},
{"level":"ERROR","timestamp":1735732801,"message":"Connection failed"}
]
```

### JSONL (one object per line)

```json
{"level":"INFO","timestamp":1735732800,"message":"User logged in"}
{"level":"ERROR","timestamp":1735732801,"message":"Connection failed"}
```

In both JSON formats quotes, backslashes and control characters are escaped, and bytes that are not valid UTF-8 are replaced by `\ufffd`.

### CSV

The message is always quoted; a double quote inside it is doubled.

```csv
level,timestamp,message
INFO,1735732800,"User logged in"
ERROR,1735732801,"Connection failed"
```

### TSV

Tab-separated. A tab, carriage return or backslash inside a message is written as `\t`, `\r` or `\\`, so every row has three fields.

```
level	timestamp	message
INFO	1735732800	User logged in
ERROR	1735732801	Connection failed
```

### RAW

Level and message only, no timestamp.

```
[INFO] User logged in
[ERROR] Connection failed
```

## Results and Statistics

Every run ends with a summary on stderr. For `./output/logproc -l ERROR -o raw logs.txt` on the two lines above:

```
=== Results ===
Total:   2
Valid:   2
Invalid: 0
Matched: 1
--- By Level ---
DEBUG:   0
INFO:    1
WARN:    0
ERROR:   1
--- Performance ---
Time:    0.00 sec
```

`Total` counts every input line. `Matched` counts the valid entries that passed all filters (equal to `Valid` when there is no filter), while `By Level` counts the valid entries before filtering. A `Files:` line is added when more than one input is given, and a `Speed:` line when the run took longer than a millisecond. `Time` covers the whole run, including the last flush of the output and the aggregation.

`--count-only` and `--stats` write no records, so stdout stays empty. `--stats hourly`, `daily` and `minute` add the matched entries per time bucket (UTC) to the summary, sorted by time; `daily` prints the date alone and `minute` prints `HH:MM`:

```
--- Aggregation (Hourly) ---
2025-01-01 12:00  D:0 I:1 W:0 E:1 (total:2)
```

`--stats by-level` adds one line per level instead:

```
--- Aggregation (By Level) ---
DEBUG : 0
INFO  : 1
WARN  : 0
ERROR : 1
```

## Follow Mode

`-f` follows the last FILE; any files before it are processed as usual. Once the existing content is done, the file is checked for appended data about every 100 ms. Each batch of new lines is processed and flushed at once, and a line is held back until its newline has arrived. Ctrl+C (or SIGTERM) stops the run, prints the results and exits with status 0; a last line that is still unfinished is not counted. That also holds while an earlier file is still being read: the run stops there, with the line it was cut off in left out, and the remaining files are not read.

A followed file has no end, so `-o json` (the default) is written as jsonl and a note says so. The file is not re-opened: truncation and rotation are not detected. `-f` is ignored, with a note, when the last input is stdin.

## Threads, Ordering and Memory

The reader hands 1 MB blocks of whole lines to the worker threads. With more than one thread (the default is 8) the blocks finish in any order, so the records come out whole but not necessarily in input order. Use `-t 1` when the order matters: it writes the records in input order. The counts and the statistics do not depend on the thread count.

Memory use does not grow with the input. The blocks come from a fixed pool (2 x threads + 2), and the reader waits while the workers hold them all, so peak memory is at most that pool plus about 2 MB: 6 MB with one thread, 20 MB with 8 and 28 MB with 12, for `--count-only` and for record output alike. A run in which the workers keep ahead of the reader touches fewer blocks and stays below that (measured on a 1.9 GB file with 40M lines: 12 to 20 MB for `--count-only -t 8`, 20 MB for `-o jsonl -t 8`).

The time statistics come on top of that and grow with the number of buckets, not with the input: every thread counts the buckets it has seen, in blocks of 64 consecutive buckets. A bucket takes about 5 bytes per thread where the entries are dense in time, and about 40 once a thread has counted more than 255 entries of one level in a bucket of its block; a bucket with no neighbours costs a whole block of about 300 bytes. `--stats minute` on the 1.9 GB file (about 970,000 minutes spread over two years, in random order) peaked at about 57 MB with 8 threads and 10 MB with one.

## Log Generator

```
./output/genlog <count> [output_file] [--start DATE --end DATE]
```

Writes `count` lines (suffixes `K`, `M`, `B`) to the file or to stdout: about 90% valid entries and 10% invalid lines. Timestamps are random, in 2024-2025 by default or from `--start` up to but not including `--end` (same date forms as `--after`).

## Make Targets

| Target                  | Description                                                    |
| ----------------------- | -------------------------------------------------------------- |
| `make`                  | Build `output/logproc` and `output/genlog`                     |
| `make test`             | Smoke test: generate 100K lines and count them                 |
| `make unit-test`        | Zig unit tests of the parser (does not need the binaries)      |
| `make integration-test` | End-to-end tests of the built binaries                         |
| `make test-all`         | Unit and integration tests                                     |
| `make benchmark`        | `dd` against `logproc --count-only` (see Performance)          |
| `make assembly`         | Assembly listings of the four components in `output/`          |
| `make clean`            | Remove everything the build and the tests generate             |

Variables, set on the command line (`make benchmark BENCH_SIZE=10M BENCH_THREADS=4`):

- `BENCH_SIZE` (default `500M`) and `BENCH_THREADS` (default `8`): line count and thread count of the benchmark.
- `LOGPROC_BIN` and `GENLOG_BIN`: the binaries the integration tests run (default `./output/logproc` and `./output/genlog`).
- `ZIG_TEST_FLAGS`: extra flags for `zig test`. On macOS it defaults to an explicit `-target` for the machine's architecture.

The tests build in `./.zig-cache` and keep their temporary files there; `make clean` removes it.

## Project Structure

```
├── reader.c             # Main entry, CLI, threading, statistics
├── parser.zig           # Log parsing logic
├── processor.rs         # Filtering
├── formatter.cpp        # Output formatting
├── logentry.h           # Shared data structure
├── generate_logs.c      # Test log generator
├── test_logproc.zig     # Unit tests of the parser
├── test_integration.zig # End-to-end tests of the binaries
├── Makefile
└── output/              # Created by the build
    ├── logproc          # Main binary
    └── genlog           # Log generator
```

## License

MIT
