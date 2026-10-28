// Independent control-hazard and side-effect test.
// The pass signature is written to x10 only after every wrong-path store,
// load-to-control dependency, predictor recovery, and cache-boundary check.

    .section .text
    .option norvc
    .globl main

main:
    lui  t0, 0x80010              // scratch base = 0x8001_0000
    sw   zero, 0(t0)
    li   t1, 0x11111111
    li   t2, 1

    // Taken conditional branch: the younger store must be flushed.
    beq  t2, t2, 1f
    sw   t1, 0(t0)
1:
    lw   t3, 0(t0)
    bne  t3, zero, fail

    // JAL prediction must not allow the fall-through store to commit.
    jal  ra, 2f
    sw   t1, 0(t0)
2:
    lw   t3, 0(t0)
    bne  t3, zero, fail

    // Load-to-JALR dependency. JALR resolves in EX, so a fall-through
    // instruction can already be in flight and must be cancelled.
    la   t4, 3f
    sw   t4, 4(t0)
    lw   t5, 4(t0)
    jalr ra, 0(t5)
    sw   t1, 0(t0)
3:
    lw   t3, 0(t0)
    bne  t3, zero, fail

    // Immediate load-to-branch dependency plus wrong-path store suppression.
    sw   t2, 8(t0)
    lw   t5, 8(t0)
    beq  t5, t2, 4f
    sw   t1, 0(t0)
4:
    lw   t3, 0(t0)
    bne  t3, zero, fail

    // Load-to-store forwarding and accesses on both sides of a 64-byte line.
    li   t4, 0xA5A55A5A
    sw   t4, 12(t0)
    lw   t5, 12(t0)
    sw   t5, 60(t0)
    lw   t6, 60(t0)
    bne  t6, t4, fail
    sw   t5, 64(t0)
    lw   t6, 64(t0)
    bne  t6, t4, fail

    // Signed byte/halfword accesses at the upper edge of a cache line.
    li   t4, -128
    sb   t4, 127(t0)
    lb   t6, 127(t0)
    bne  t6, t4, fail
    li   t4, 0x8001
    sh   t4, 126(t0)
    lh   t6, 126(t0)
    li   t4, -32767
    bne  t6, t4, fail

    // Train the branch predictor taken, then force a not-taken recovery.
    li   t4, 4
5:
    addi t4, t4, -1
    bne  t4, zero, 5b
    sw   t2, 16(t0)
    lw   t5, 16(t0)
    bne  t5, t2, fail

pass:
    li   a0, 0x3000C0DE
6:
    jal  zero, 6b

fail:
    li   a0, 0xDEAD30FF
7:
    jal  zero, 7b
