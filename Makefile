CC = clang
CXX = clang++
RUSTC = rustc
STRIP = strip

all: program

./output/input.o: input.c
	$(CC) -c -Os -fno-builtin -fno-stack-protector input.c -o ./output/input.o

./output/print.o: print.cpp
	$(CXX) -c -Os -fno-builtin -fno-exceptions -fno-rtti -fno-stack-protector print.cpp -o ./output/print.o

./output/transform.o: transform.rs
	$(RUSTC) --crate-type=cdylib --emit=obj -C opt-level=s -C panic=abort transform.rs -o ./output/transform.o

./output/main.o: main.s
	$(CC) -c main.s -o ./output/main.o

program: ./output/main.o ./output/input.o ./output/print.o ./output/transform.o
	$(CC) -nostdlib -e _main ./output/main.o ./output/input.o ./output/print.o ./output/transform.o -o ./output/program
	$(STRIP) ./output/program

run: program
	./output/program

clean:
	rm -f ./output/*.o ./output/*.a ./output/program

.PHONY: all clean run