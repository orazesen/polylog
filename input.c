// Pure C - no standard library, direct syscall
static long read_syscall(int fd, void *buf, unsigned long count) {
    long ret;
    __asm__ volatile(
        "mov x0, %1\n"
        "mov x1, %2\n"
        "mov x2, %3\n"
        "mov x16, #3\n"
        "svc #0x80\n"
        "mov %0, x0\n"
        : "=r"(ret)
        : "r"((long)fd), "r"(buf), "r"(count)
        : "x0", "x1", "x2", "x16"
    );
    return ret;
}

int get_input(void) {
    char buf[16];
    long n = read_syscall(0, buf, 15);
    if (n <= 0) return 0;

    int result = 0;
    for (int i = 0; i < n && buf[i] >= '0' && buf[i] <= '9'; i++) {
        result = result * 10 + (buf[i] - '0');
    }
    return result;
}
