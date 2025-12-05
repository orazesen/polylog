# polylog

A high-performance multi-language log processor that achieves **3.3 GB/s** throughput — matching raw disk I/O speed.

## Architecture

```
C (reader) → Zig (parser) → Rust (processor) → C++ (formatter)
```

| Component       | Language | Role                                |
| --------------- | -------- | ----------------------------------- |
| `reader.c`      | C        | File I/O, CLI, multi-threading      |
| `parser.zig`    | Zig      | Log line parsing, validation        |
| `processor.rs`  | Rust     | Filtering, statistics               |
| `formatter.cpp` | C++      | Output formatting (JSON, CSV, etc.) |

## Performance

Benchmarked on Apple M2 Pro with 500M log entries (~22 GB):

| Method                  | Speed          |
| ----------------------- | -------------- |
| Raw disk read (`dd`)    | 3,328 MB/s     |
| **polylog (8 threads)** | **3,327 MB/s** |
| polylog (1 thread)      | 529 MB/s       |

Processing speed matches raw disk I/O — the pipeline is completely I/O-bound.

## Requirements

- **clang** (C/C++ compiler)
- **zig** (0.15+)
- **rustc** (Rust compiler)
- **make**

## Quick Start

```bash
# Build
make

# Generate test logs
./output/genlog 100K logs.txt

# Process logs
./output/logproc logs.txt

# Run all tests
make test-all

# Run benchmark
make benchmark
```

## Usage

```bash
./output/logproc [OPTIONS] FILE...

Options:
  -t N              Number of threads (default: 4)
  -l LEVELS         Filter by level (DEBUG,INFO,WARN,ERROR)
  -o FORMAT         Output format: json, jsonl, csv, tsv, raw
  -O FILE           Write output to file
  --count-only      Only show statistics, no output
  --stats MODE      Statistics: hourly, daily, minute, by-level
  --split-by-level  Write to debug.txt, info.txt, warn.txt, error.txt
  --config FILE     Load settings from config file
  -h, --help        Show help
```

## Examples

```bash
# JSON output with ERROR filter
./output/logproc -o json -l ERROR logs.txt

# JSONL streaming format
./output/logproc -o jsonl logs.txt

# Hourly statistics
./output/logproc --stats hourly logs.txt

# Split output by log level
./output/logproc --split-by-level logs.txt

# Multi-threaded processing
./output/logproc -t 8 large_logs.txt
```

## Log Format

Input format:

```
2025-01-01 12:00:00 INFO User logged in
2025-01-01 12:00:01 ERROR Connection failed
```

## Output Formats

### JSON

```json
{ "level": "INFO", "timestamp": 1735732800, "message": "User logged in" }
```

### JSONL (one object per line)

```json
{"level":"INFO","timestamp":1735732800,"message":"User logged in"}
{"level":"ERROR","timestamp":1735732801,"message":"Connection failed"}
```

### CSV

```csv
level,timestamp,message
INFO,1735732800,User logged in
ERROR,1735732801,Connection failed
```

### RAW

```
[INFO] 2025-01-01 12:00:00 | User logged in
[ERROR] 2025-01-01 12:00:01 | Connection failed
```

## Make Targets

| Target                  | Description                  |
| ----------------------- | ---------------------------- |
| `make`                  | Build logproc and genlog     |
| `make test`             | Quick test with 100K logs    |
| `make unit-test`        | Run 36 Zig unit tests        |
| `make integration-test` | Run 22 Zig integration tests |
| `make test-all`         | Run all 58 tests             |
| `make benchmark`        | Benchmark with 500M logs     |
| `make clean`            | Remove build artifacts       |

## Project Structure

```
├── reader.c           # Main entry, CLI, threading
├── parser.zig         # Log parsing logic
├── processor.rs       # Filtering, stats
├── formatter.cpp      # Output formatting
├── logentry.h         # Shared data structure
├── generate_logs.c    # Test log generator
├── test_logproc.zig   # Unit tests (36)
├── test_integration.zig # Integration tests (22)
├── Makefile
└── output/
    ├── logproc        # Main binary
    └── genlog         # Log generator
```

## License

MIT
