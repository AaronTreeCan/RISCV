# hazards.S - pipeline hazard cases, each followed by a self-check
#
# riscv-tests already cover the common bypass distances; these are the
# corner cases a pipeline most often gets wrong. tb_soc also compares every
# retired instruction against the single-cycle core, so a wrong value is
# reported at the exact instruction even if a check below would miss it.
# Ends like riscv-tests: a7 = 93, a0 = 0 (pass) or failing check number, ECALL.

    .section .text.start
    .globl _start
_start:
    li      a7, 93
    la      s0, data

    # 1: forward from MEM beats WB (same register written twice in a row)
    li      a0, 1
    li      t0, 1
    li      t0, 2
    addi    t1, t0, 0               # must see 2, not 1
    li      t2, 2
    bne     t1, t2, fail

    # 2: writes to x0 must never be forwarded
    li      a0, 2
    addi    zero, zero, 7
    add     t1, zero, zero          # MEM-stage forward of x0
    bnez    t1, fail
    addi    zero, zero, 7
    nop
    add     t1, zero, zero          # WB-stage forward of x0
    bnez    t1, fail

    # 3: load-use into an ALU op (1-cycle stall)
    li      a0, 3
    lw      t0, 0(s0)               # 0x12345678
    addi    t1, t0, 1
    li      t2, 0x12345679
    bne     t1, t2, fail

    # 4: load-use into a branch compare
    li      a0, 4
    lw      t0, 0(s0)
    bne     t0, t2, 1f              # t0 != 0x12345679, so this must be taken
    j       fail
1:

    # 5: load-use into a store's data (rs2) and address (rs1)
    li      a0, 5
    li      t1, 0x0badf00d
    sw      t1, 8(s0)
    li      t0, 0
    lw      t0, 8(s0)
    sw      t0, 4(s0)               # data hazard on rs2: must store 0x0badf00d
    lw      t1, 4(s0)
    li      t2, 0x0badf00d
    bne     t1, t2, fail
    la      t3, data + 8
    sw      t3, 12(s0)
    lw      t4, 12(s0)
    sw      t2, 0(t4)               # address hazard on rs1 (stores to data+8)
    lw      t5, 8(s0)
    bne     t5, t2, fail

    # 6: load followed by a load that uses it as the address
    li      a0, 6
    li      t4, 0
    lw      t4, 12(s0)              # = data + 8
    lw      t5, 0(t4)
    bne     t5, t2, fail

    # 7: JALR with its base register just written (forwarded from MEM)
    li      a0, 7
    la      t0, 2f
    jalr    ra, 0(t0)
    j       fail
2:

    # 8: JALR right after a load of its base (load-use + jump)
    li      a0, 8
    la      t0, 3f
    sw      t0, 4(s0)
    lw      t1, 4(s0)
    jalr    zero, 0(t1)
    j       fail
3:

    # 9: link register used immediately after JAL
    li      a0, 9
    jal     ra, 4f
4:  la      t0, 4b
    bne     ra, t0, fail

    # 10: taken branch squashes the two instructions behind it
    li      a0, 10
    li      t0, 0
    beq     zero, zero, 5f
    addi    t0, t0, 1               # wrong path: must not execute
    addi    t0, t0, 1               # wrong path: must not execute
5:  bnez    t0, fail

    # 11: store in the shadow of a taken branch must not write memory
    li      a0, 11
    sw      zero, 4(s0)
    li      t1, 0x55
    j       6f
    sw      t1, 4(s0)               # wrong path
6:  lw      t2, 4(s0)
    bnez    t2, fail

    # 12: a value 3 instructions back comes through the WB -> ID bypass
    li      a0, 12
    li      t0, 42
    nop
    nop
    addi    t1, t0, 0
    li      t2, 42
    bne     t1, t2, fail

    # 13: second operand (rs2) forwarded from WB, two instructions back
    li      a0, 13
    li      t0, 5
    nop
    sub     t1, zero, t0
    li      t2, -5
    bne     t1, t2, fail

    li      a0, 0
fail:
    ecall

    .data
    .align 4
data:
    .word 0x12345678, 0, 0, 0
