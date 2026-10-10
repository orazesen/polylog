# Log Processor - Multi-language Pipeline (Multi-threaded)
# C (reader) -> Zig (parser) -> Rust (processor) -> C++ (formatter)

CC = clang
CXX = clang++
RUSTC = rustc
ZIG = zig
STRIP = strip

# Optimized flags for multi-threaded build
CFLAGS = -O3 -DNDEBUG -pthread -march=native
CXXFLAGS = -O3 -DNDEBUG -pthread -fno-exceptions -fno-rtti
RUSTFLAGS = -C opt-level=3 -C panic=abort -C lto=yes -C codegen-units=1
ZIGFLAGS = -O ReleaseFast

# 'zig test' can fail to link for the implicit native target on macOS,
# so the target is named explicitly there (override: make ZIG_TEST_FLAGS=...)
ifeq ($(shell uname -s),Darwin)
ifeq ($(shell uname -m),arm64)
ZIG_TEST_FLAGS ?= -target aarch64-macos
else ifeq ($(shell uname -m),x86_64)
ZIG_TEST_FLAGS ?= -target x86_64-macos
endif
endif
ZIG_TEST_FLAGS ?=

# Benchmark input size (genlog count) and logproc thread count
BENCH_SIZE ?= 500M
BENCH_THREADS ?= 8

all: ./output/logproc ./output/genlog

# Short aliases for the binaries
logproc: ./output/logproc
genlog: ./output/genlog

# Order-only prerequisite of everything written to ./output
./output:
	mkdir -p ./output

# === Multi-threaded 4-language version ===
./output/reader.o: reader.c logentry.h | ./output
	$(CC) -c $(CFLAGS) reader.c -o ./output/reader.o

./output/parser.o: parser.zig | ./output
	$(ZIG) build-obj $(ZIGFLAGS) parser.zig -femit-bin=./output/parser.o

./output/processor.o: processor.rs | ./output
	$(RUSTC) --crate-type=staticlib --emit=obj $(RUSTFLAGS) processor.rs -o ./output/processor.o

./output/formatter.o: formatter.cpp logentry.h | ./output
	$(CXX) -c $(CXXFLAGS) formatter.cpp -o ./output/formatter.o

./output/logproc: ./output/reader.o ./output/parser.o ./output/processor.o ./output/formatter.o
	$(CXX) $(CFLAGS) \
		./output/reader.o ./output/parser.o ./output/processor.o ./output/formatter.o \
		-o ./output/logproc
	$(STRIP) ./output/logproc

# === Log generator ===
./output/genlog: generate_logs.c | ./output
	$(CC) -O3 generate_logs.c -o ./output/genlog
	$(STRIP) ./output/genlog

# === Utilities ===
test: ./output/logproc ./output/genlog
	@echo "=== Generating 100K test logs ==="
	./output/genlog 100K test_logs.txt
	@echo ""
	@echo "=== Testing multi-threaded 4-language pipeline ==="
	./output/logproc --count-only -t 4 test_logs.txt
	@rm -f test_logs.txt

# === Unit Tests (Zig) ===
# The tests build in a cache inside the checkout: from the shared default
# cache zig can reuse a test binary that another directory built from its own
# copy of parser.zig, and a broken parser would then still pass
unit-test:
	@echo "=== Running Zig unit tests ==="
	$(ZIG) test $(ZIG_TEST_FLAGS) --cache-dir ./.zig-cache test_logproc.zig

# === Integration Tests (Zig) ===
integration-test: ./output/logproc ./output/genlog
	@echo "=== Running Zig integration tests ==="
	$(ZIG) test $(ZIG_TEST_FLAGS) --cache-dir ./.zig-cache test_integration.zig

# === All Tests ===
test-all: unit-test integration-test
	@echo ""
	@echo "=== All tests passed ==="

# === Benchmark: Disk Read vs Processing ===
benchmark: ./output/logproc ./output/genlog
	@echo "=== Generating $(BENCH_SIZE) test logs ==="
	@./output/genlog $(BENCH_SIZE) bench_logs.txt
	@FILE_SIZE=$$(ls -l bench_logs.txt | awk '{print $$5}'); \
	FILE_MB=$$(echo "scale=2; $$FILE_SIZE / 1048576" | bc); \
	echo "File size: $$FILE_MB MB"; \
	echo ""; \
	echo "=== Raw Disk Read (dd bs=1M) ==="; \
	TIME_START=$$(python3 -c "import time; print(time.time())"); \
	dd if=bench_logs.txt of=/dev/null bs=1M 2>/dev/null; \
	TIME_END=$$(python3 -c "import time; print(time.time())"); \
	DISK_TIME=$$(echo "scale=4; $$TIME_END - $$TIME_START" | bc); \
	DISK_SPEED=$$(echo "scale=0; $$FILE_MB / $$DISK_TIME" | bc); \
	echo "Time: $${DISK_TIME}s"; \
	echo "Speed: $${DISK_SPEED} MB/s"; \
	echo ""; \
	echo "=== logproc Processing ($(BENCH_THREADS) threads) ==="; \
	./output/logproc --count-only -t $(BENCH_THREADS) bench_logs.txt 2>&1 | grep -E "(Time:|Speed:)"
	@rm -f bench_logs.txt

# Removes everything this Makefile generates; ./output goes too once it is empty
clean:
	rm -f ./output/*.o ./output/*.s ./output/logproc ./output/genlog
	rm -f test_logs.txt bench_logs.txt
	rm -rf ./.zig-cache
	@rmdir ./output 2>/dev/null || true

# === Generate Assembly Code ===
assembly: ./output/reader.s ./output/parser.s ./output/processor.s ./output/formatter.s
	@echo "=== Assembly files generated in ./output/ ==="

./output/reader.s: reader.c logentry.h | ./output
	$(CC) -S $(CFLAGS) reader.c -o ./output/reader.s

# -fno-emit-bin: otherwise zig also drops parser.o into the current directory
./output/parser.s: parser.zig | ./output
	$(ZIG) build-obj $(ZIGFLAGS) parser.zig -fno-emit-bin -femit-asm=./output/parser.s

./output/processor.s: processor.rs | ./output
	$(RUSTC) --crate-type=staticlib --emit=asm $(RUSTFLAGS) processor.rs -o ./output/processor.s

./output/formatter.s: formatter.cpp logentry.h | ./output
	$(CXX) -S $(CXXFLAGS) formatter.cpp -o ./output/formatter.s

# A failed recipe (e.g. strip after a successful link) must not leave a
# target behind that looks up to date
.DELETE_ON_ERROR:

.PHONY: all logproc genlog clean test unit-test integration-test test-all benchmark assembly
