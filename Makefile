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

all: logproc genlog

# === Multi-threaded 4-language version ===
./output/reader.o: reader.c logentry.h
	$(CC) -c $(CFLAGS) reader.c -o ./output/reader.o

./output/parser.o: parser.zig
	$(ZIG) build-obj $(ZIGFLAGS) parser.zig -femit-bin=./output/parser.o

./output/processor.o: processor.rs
	$(RUSTC) --crate-type=staticlib --emit=obj $(RUSTFLAGS) processor.rs -o ./output/processor.o 2>/dev/null

./output/formatter.o: formatter.cpp
	$(CXX) -c $(CXXFLAGS) formatter.cpp -o ./output/formatter.o

logproc: ./output/reader.o ./output/parser.o ./output/processor.o ./output/formatter.o
	$(CXX) $(CFLAGS) \
		./output/reader.o ./output/parser.o ./output/processor.o ./output/formatter.o \
		-o ./output/logproc
	$(STRIP) ./output/logproc

# === Log generator ===
genlog: generate_logs.c logentry.h
	$(CC) -O3 generate_logs.c -o ./output/genlog
	$(STRIP) ./output/genlog

# === Utilities ===
test: logproc genlog
	@echo "=== Generating 100K test logs ==="
	./output/genlog 100K test_logs.txt
	@echo ""
	@echo "=== Testing multi-threaded 4-language pipeline ==="
	./output/logproc --count-only -t 4 test_logs.txt
	@rm -f test_logs.txt

# === Unit Tests (Zig) ===
unit-test:
	@echo "=== Running Zig unit tests (36 tests) ==="
	$(ZIG) test test_logproc.zig

# === Integration Tests (Zig) ===
integration-test: logproc genlog
	@echo "=== Running Zig integration tests (22 tests) ==="
	$(ZIG) test test_integration.zig

# === All Tests ===
test-all: unit-test integration-test
	@echo ""
	@echo "=== All 58 tests passed ==="

# === Benchmark: Disk Read vs Processing ===
benchmark: logproc genlog
	@echo "=== Generating 500M test logs ==="
	@./output/genlog 500M bench_logs.txt
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
	echo "=== logproc Processing (8 threads) ==="; \
	./output/logproc --count-only -t 8 bench_logs.txt 2>&1 | grep -E "(Time:|Speed:)"
	@rm -f bench_logs.txt

clean:
	rm -f ./output/*.o ./output/logproc ./output/genlog
	rm -f test_logs.txt

# === Generate Assembly Code ===
assembly: ./output/reader.s ./output/parser.s ./output/processor.s ./output/formatter.s
	@echo "=== Assembly files generated in ./output/ ==="

./output/reader.s: reader.c logentry.h
	$(CC) -S $(CFLAGS) reader.c -o ./output/reader.s

./output/parser.s: parser.zig
	$(ZIG) build-obj $(ZIGFLAGS) parser.zig -femit-asm=./output/parser.s

./output/processor.s: processor.rs
	$(RUSTC) --crate-type=staticlib --emit=asm $(RUSTFLAGS) processor.rs -o ./output/processor.s 2>/dev/null

./output/formatter.s: formatter.cpp
	$(CXX) -S $(CXXFLAGS) formatter.cpp -o ./output/formatter.s

.PHONY: all clean test unit-test integration-test test-all benchmark assembly
