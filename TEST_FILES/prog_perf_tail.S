    .section .text
    .option norvc
    .globl main
main:
    j tail_callee
tail_callee:
    li a0, 43
    ret
