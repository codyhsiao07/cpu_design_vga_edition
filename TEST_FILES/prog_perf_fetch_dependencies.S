// Dense fetch regression: WB/ID same-edge reads, adjacent store/load/use,
// forwarded EX operands held behind MEM, and multiply completion.
.section .text
.globl main
main:
    li t0, 19
    li t1, 3
    li t2, 5
    add t3, t0, t1
    li t4, 22
    bne t3, t4, fail

    la t0, fetch_scratch
    li t1, 0x12345678
    sw t1, 0(t0)
    lw t2, 0(t0)
    addi t3, t2, 7
    addi t4, t1, 7
    bne t3, t4, fail

    li t4, 25
    lw t2, 256(t0)
    addi t5, t4, 3
    li t6, 28
    bne t5, t6, fail
    bnez t2, fail

    li t1, 7
    li t2, 9
    mul t3, t1, t2
    addi t4, t1, 11
    add t5, t3, t4
    li t6, 81
    bne t5, t6, fail
    li a0, 0x5f07c0de
    ret
fail:
    li a0, -1
    ret

.section .bss
.balign 64
fetch_scratch:
    .space 320
