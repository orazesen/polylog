    .globl _main
.align 4

_main:
    stp x29, x30, [sp, #-16]!
    mov x29, sp

    bl _get_input
    mov w0, w0

    bl _transform_input
    mov w0, w0

    bl _print_result

    mov w0, #0
    ldp x29, x30, [sp], #16
    ret