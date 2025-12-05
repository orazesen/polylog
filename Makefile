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

clean:
	rm -f ./output/*.o ./output/logproc ./output/genlog
	rm -f test_logs.txt

.PHONY: all clean test unit-test integration-test test-all
