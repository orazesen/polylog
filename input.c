#include <stdio.h>

int get_input(void) {
    int x = 0;
    if (scanf("%d", &x) != 1) {
        return 0;
    }
    return x;
}
