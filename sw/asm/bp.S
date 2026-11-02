# bp.S - corner cases for the branch predictor on the dual-issue core
#
# Each case trains the predictor with a loop, then does something the
# prediction gets wrong (or must not apply to). .balign 8 decides which
# word of a fetch pair a branch sits in (slot 0 = 8-byte aligned, slot 1 = +4).
# tb_soc checks every retired instruction against the single-cycle core, so
# a wrong-path instruction that retires is caught even if a check here misses.
# Ends like riscv-tests: a7 = 93, a0 = 0 (pass) or failing check number, ECALL.

    .section .text.start
    .globl _start
_start:
    li      a7, 93

    # 1: loop branch in slot 0: trained taken, then the exit is a mispredict.
    #    The word after the branch (slot 1) must not run while it's predicted
    #    taken, and must run once on the exit.
    li      a0, 1
    li      t0, 8
    li      t1, 0
    .balign 8
1:  addi    t0, t0, -1              # slot 0
    nop                             # slot 1
    bnez    t0, 1b                  # slot 0 of the next pair
    addi    t1, t1, 1               # slot 1: only on the way out
    li      t2, 1
    bne     t1, t2, fail

    # 2: loop branch in slot 1
    li      a0, 2
    li      t0, 8
    li      t1, 0
    .balign 8
2:  addi    t1, t1, 3               # slot 0
    addi    t0, t0, -1              # slot 1
    nop                             # slot 0
    bnez    t0, 2b                  # slot 1
    li      t2, 24
    bne     t1, t2, fail

    # 3: jump into the second word of a pair whose first word is a trained
    #    taken branch: that BTB entry must not apply to a fetch at +4
    li      a0, 3
    li      t0, 6
    li      t1, 0
    .balign 8
3:  addi    t1, t1, 1
    addi    t0, t0, -1
    nop
    nop
pair3:
    bnez    t0, 3b                  # slot 0, trained taken
    addi    t1, t1, 100             # slot 1
    li      t2, 106
    beq     t1, t2, 13f             # first time out: t1 = 6 loop + 100 on exit
    li      t2, 206                 # second time: only the +100 ran again
    bne     t1, t2, fail
    j       14f
13: la      t3, pair3 + 4
    li      t0, 5                   # nonzero: the bnez would be taken
    jr      t3                      # land on the addi, skipping the bnez
14:

    # 4: direction flip: a branch not taken 6 times, then taken 6 times.
    #    The 2-bit counter needs two wrong guesses to flip.
    li      a0, 4
    li      t0, 12
    li      t1, 0                   # times taken
    li      t4, 6
    .balign 8
4:  slt     t3, t4, t0              # t3 = (t0 > 6)
    beqz    t3, 5f                  # slot 1: not taken while t0 > 6
    addi    t1, t1, 1
5:  addi    t0, t0, -1
    bnez    t0, 4b
    li      t2, 6
    bne     t1, t2, fail

    # 5: JALR to a changing target: the BTB's stored target is wrong
    #    every time, so each one must redirect to the real target
    li      a0, 5
    li      t1, 0
    li      t0, 6
    la      s0, add1
    la      s1, add10
6:  andi    t3, t0, 1
    mv      t4, s0
    beqz    t3, 7f
    mv      t4, s1
7:  jalr    ra, 0(t4)
    addi    t0, t0, -1
    bnez    t0, 6b
    li      t2, 33                  # 3 * 1 + 3 * 10
    bne     t1, t2, fail

    # 6: calls in a loop: JAL and the return (JALR) both hit in the BTB
    li      a0, 6
    li      t1, 0
    li      t0, 5
8:  jal     ra, add1
    jal     ra, add10
    addi    t0, t0, -1
    bnez    t0, 8b
    li      t2, 55
    bne     t1, t2, fail

    # 7: load in slot 0, branch on its value in slot 1: the branch waits
    #    (load-use), then moves to lane 0 with its prediction intact
    li      a0, 7
    la      s0, data
    li      t0, 6
    li      t1, 0
    .balign 8
9:  addi    t1, t1, 1               # slot 0
    addi    t0, t0, -1              # slot 1
    sw      t0, 0(s0)               # slot 0
    nop                             # slot 1
    lw      t3, 0(s0)               # slot 0
    bnez    t3, 9b                  # slot 1, needs t3
    li      t2, 6
    bne     t1, t2, fail

    # 8: two branches in one pair, the first not taken and the second taken
    #    (only one BTB entry per pair: they fight over it)
    li      a0, 8
    li      t0, 6
    li      t1, 0
    .balign 8
10: addi    t1, t1, 1
    addi    t0, t0, -1
    beqz    t0, 11f                 # slot 0: not taken until the last pass
    bnez    t0, 10b                 # slot 1: taken
11: li      t2, 6
    bne     t1, t2, fail

    # 9: a predicted-taken branch in slot 0 whose slot-1 word writes a
    #    register: that write must not happen on the taken path
    li      a0, 9
    li      t0, 6
    li      t1, 0
    .balign 8
12: addi    t0, t0, -1
    nop
    bnez    t0, 12b                 # slot 0
    li      t1, 7                   # slot 1
    li      t2, 7
    bne     t1, t2, fail            # (and lockstep checks t1 never got 7 earlier)

    li      a0, 0
fail:
    ecall

add1:
    addi    t1, t1, 1
    ret
add10:
    addi    t1, t1, 10
    ret

    .data
    .align 4
data:
    .word 0, 0, 0, 0
