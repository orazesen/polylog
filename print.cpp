#include <cstdio>

extern "C" void print_result(int x)
{
    std::printf("%d\n", x);
}
