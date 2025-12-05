CC = clang
CXX = clang++
RUSTC = rustc

all: program

./output/input.o: input.c
	$(CC) -c input.c -o ./output/input.o

./output/print.o: print.cpp
	$(CXX) -c print.cpp -o ./output/print.o

./output/libtransform.a: transform.rs
	$(RUSTC) --crate-type=staticlib transform.rs -o ./output/libtransform.a

./output/main.o: main.s
	$(CC) -c main.s -o ./output/main.o

program: ./output/main.o ./output/input.o ./output/print.o ./output/libtransform.a
	$(CXX) ./output/main.o ./output/input.o ./output/print.o -L./output -ltransform -o ./output/program

run: program
	./output/program
clean:
	rm -f ./output/*.o ./output/*.a ./output/program

.PHONY: all clean run