// Pure C++ - no standard library, direct syscall
static void write_syscall(int fd, const void *buf, unsigned long count)
{
    __asm__ volatile(
        "mov x0, %0\n"
        "mov x1, %1\n"
        "mov x2, %2\n"
        "mov x16, #4\n"
        "svc #0x80\n"
        :
        : "r"((long)fd), "r"(buf), "r"(count)
        : "x0", "x1", "x2", "x16");
}

extern "C" void print_result(int x)
{
    char buf[16];
    int i = 15;
    buf[i] = '\n';

    if (x == 0)
    {
        buf[--i] = '0';
    }
    else
    {
        while (x > 0 && i > 0)
        {
            buf[--i] = '0' + (x % 10);
            x /= 10;
        }
    }
    write_syscall(1, &buf[i], 16 - i);
}
