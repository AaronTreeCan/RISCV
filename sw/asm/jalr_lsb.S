# jalr_lsb.S - JALR must clear bit 0 of its target (rs1 + imm)
#
# The official rv32ui jalr test never jumps to an odd address, so a core
# that forgets this rule still passes it. Ends like riscv-tests:
# a7 = 93, a0 = 0 (pass) or failing check number, then ECALL.

    .section .text.start
    .globl _start
_start:
    li      a7, 93

    # 1: odd target from rs1 (target | 1)
    li      a0, 1
    la      t0, land1
    addi    t0, t0, 1
    jalr    ra, 0(t0)
    j       fail
land1:
    la      t1, land1 - 4
    bne     ra, t1, fail            # link = address of the jalr + 4

    # 2: odd target from the immediate
    li      a0, 2
    la      t0, land2
    jalr    ra, 1(t0)
    j       fail
land2:

    # 3: writes to x0 are dropped
    li      a0, 3
    addi    zero, zero, 5
    bnez    zero, fail

    li      a0, 0
fail:
    ecall
