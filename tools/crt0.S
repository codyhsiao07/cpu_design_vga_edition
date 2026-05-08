// Minimal startup for RV32I bare-metal tests.
// - Set stack pointer
// - Call main
// - Move return value to x8 (s0/fp) for TB observability
// - Spin forever

    .section .text.start
    .globl _start
_start:
    la   sp, __stack_top
    la   gp, __global_pointer$
    la   t0, __bss_start
    la   t1, __bss_end
    li   t2, 0
1:
    bgeu t0, t1, 2f //清理bass
    sw   t2, 0(t0)
    addi t0, t0, 4
    jal  x0, 1b
2:
    call main
    addi x8, a0, 0
3:
    jal  x0, 3b
