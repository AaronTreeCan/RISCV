# dual.S - corner cases for the dual-issue core, each with a self-check
#
# Instructions are laid out with .balign 8 so that we know which ones land
# in the same fetch pair (lane 0 = the 8-byte aligned word, lane 1 = +4).
# tb_soc compares every retired instruction against the single-cycle core,
# so a wrong value is caught at that instruction even if a check here misses.
# Ends like riscv-tests: a7 = 93, a0 = 0 (pass) or failing check number, ECALL.

    .section .text.start
    .globl _start
_start:
    li      a7, 93
    la      s0, data

    # 1: write-after-write inside a pair: the younger (lane 1) must win
    li      a0, 1
    .balign 8
    li      t0, 11                  # lane 0
    li      t0, 22                  # lane 1, same register
    addi    t1, t0, 0
    li      t2, 22
    bne     t1, t2, fail

    # 2: read-after-write inside a pair: must split, second sees the new value
    li      a0, 2
    .balign 8
    li      t0, 5                   # lane 0
    addi    t1, t0, 1               # depends on lane 0 -> issues next cycle
    li      t2, 6
    bne     t1, t2, fail

    # 3: lane 1 result forwarded into the next pair's lane 0 and lane 1
    li      a0, 3
    .balign 8
    li      t3, 0                   # lane 0
    li      t0, 7                   # lane 1 produces t0
    add     t1, t0, t0              # next pair, lane 0 reads it (from MEM lane 1)
    add     t2, zero, t0            # lane 1 reads it too
    li      t4, 14
    bne     t1, t4, fail
    li      t4, 7
    bne     t2, t4, fail

    # 4: taken branch in lane 0 kills its lane-1 partner
    li      a0, 4
    li      t0, 0
    .balign 8
    beq     zero, zero, 1f          # lane 0, taken
    addi    t0, t0, 1               # lane 1: wrong path, must not retire
    addi    t0, t0, 1               # wrong path
    addi    t0, t0, 1               # wrong path
1:  bnez    t0, fail

    # 5: not-taken branch in lane 0 keeps its lane-1 partner
    li      a0, 5
    li      t0, 0
    .balign 8
    bne     zero, zero, fail        # lane 0, not taken
    addi    t0, t0, 1               # lane 1: must retire
    li      t1, 1
    bne     t0, t1, fail

    # 6: jump to the second word of a pair (single-instruction fetch)
    li      a0, 6
    li      t0, 0
    j       2f
    .balign 8
    addi    t0, t0, 1               # lane 0 of the pair: skipped
2:  addi    t0, t0, 2               # target: second word
    li      t1, 2
    bne     t0, t1, fail

    # 7: load in lane 0, user in lane 1 of the same pair (must split)
    li      a0, 7
    .balign 8
    lw      t0, 0(s0)               # lane 0
    addi    t1, t0, 1               # lane 1 wants it: split + load-use stall
    li      t2, 0x12345679
    bne     t1, t2, fail

    # 8: a load in the second slot can't use lane 1, so the pair splits and
    #    the load issues next cycle in lane 0; its user then sits in lane 1
    #    of the following pair (load-use check on lane 1)
    li      a0, 8
    .balign 8
    nop
    lw      t0, 0(s0)               # second slot: split
    nop
    addi    t1, t0, 1               # lane 1, needs the load
    bne     t1, t2, fail

    # 9: store in lane 0 with an ALU op in lane 1, then read back
    li      a0, 9
    li      t0, 0x0badf00d
    .balign 8
    sw      t0, 4(s0)               # lane 0
    addi    t1, zero, 3             # lane 1
    lw      t2, 4(s0)
    bne     t2, t0, fail
    li      t3, 3
    bne     t1, t3, fail

    # 10: both lanes write, then both are read 3 instructions later (WB -> ID bypass, 2 ports)
    li      a0, 10
    .balign 8
    li      t0, 100                 # lane 0
    li      t1, 200                 # lane 1
    nop
    nop
    add     t2, t0, t1
    li      t3, 300
    bne     t2, t3, fail

    # 11: writes to x0 in either lane never forward
    li      a0, 11
    .balign 8
    addi    zero, zero, 1           # lane 0
    addi    zero, zero, 2           # lane 1
    add     t0, zero, zero
    bnez    t0, fail

    # 12: write-after-write pair, read exactly when the pair is in WB
    #     (two pairs behind it): the WB -> ID bypass must pick lane 1
    li      a0, 12
    .balign 8
    li      t0, 11                  # lane 0
    li      t0, 22                  # lane 1
    nop
    nop
    nop
    nop
    addi    t1, t0, 0               # reads t0 in ID while the pair is in WB
    li      t2, 22
    bne     t1, t2, fail

    # 13: write-after-write pair, read long after: the register file itself
    #     must have kept the lane-1 value (write port 1 wins)
    li      a0, 13
    .balign 8
    li      t0, 33                  # lane 0
    li      t0, 44                  # lane 1
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    addi    t1, t0, 0
    li      t2, 44
    bne     t1, t2, fail

    # 14: ECALL is never paired: the instruction after it must not retire
    li      a0, 0
    .balign 8
fail:
    ecall                           # lane 0
    addi    a0, a0, 1               # would be lane 1: must be squashed

    .data
    .align 4
data:
    .word 0x12345678, 0, 0, 0
