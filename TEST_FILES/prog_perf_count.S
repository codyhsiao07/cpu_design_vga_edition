// Directed retirement test: real NOP/x0 writes, stores, load-use, loop,
// long EX holding an older MEM payload, wrong-path store, nested returns.
    .section .text
    .option norvc
    .option norelax
    .globl main
main:
    addi sp, sp, -16
    sw ra, 12(sp)
    sw s0, 8(sp)
    nop
    addi zero, zero, 7
    li t0, 3
1:
    addi t0, t0, -1
    bne t0, zero, 1b
    sw t0, 0(sp)
    lw t1, 0(sp)
    addi t1, t1, 1
    li t2, 7
    li t3, 9
    sw t2, 0(sp)             // store held in MEM by the following multiply
    mul t4, t2, t3
    lw t1, 0(sp)             // load held in MEM by the following divide
    div t5, t4, t2
    rem t6, t4, t3
    lui t0, 0x40000
    li t1, 72               // UART emits exactly one 'H', despite long EX hold
    sw t1, 0(t0)
    mul t6, t2, t3
    beq zero, zero, 2f
    sw t4, 0(sp)
2:
    li a0, 41
    jal ra, helper
    lw ra, 12(sp)
    lw s0, 8(sp)
    addi sp, sp, 16
    ret
helper:
    addi a0, a0, 1
    ret
