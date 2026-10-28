// Opt-in profiler startup: the JAL and its unique return target define the scope.
    .section .text.start
    .globl _start, __perf_main_call, __perf_main_return
    .option norvc
    .option norelax
_start:
    la sp, __stack_top
    la gp, __global_pointer$
    la t0, __bss_start
    la t1, __bss_end
1:
    bgeu t0, t1, 2f
    sw zero, 0(t0)
    addi t0, t0, 4
    j 1b
2:
    lui t3, 0x40010
    la t0, __perf_main_call
    sw t0, 8(t3)
    la t0, __perf_main_return
    sw t0, 12(t3)
    li t0, 1
    sw t0, 16(t3)
__perf_main_call:
    jal ra, main
__perf_main_return:
    // a0 still holds main's result. Reporting returns the same value.
    call perf_report
    mv s0, a0
3:
    j 3b
