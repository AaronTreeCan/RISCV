# muldiv.S - M extension corner cases for the pipelined cores
#
# The official rv32um tests check each instruction's arithmetic. This file
# checks the pipeline around it: forwarding into and out of the multiplier
# and the 34-cycle divider, stalls, flushes, and pairing on the dual-issue
# core (.balign 8 puts the next two instructions in one fetch pair).
# tb_soc compares every retired instruction against the single-cycle core.
# Ends like riscv-tests: a7 = 93, a0 = 0 (pass) or failing check number, ECALL.

    .section .text.start
    .globl _start
_start:
    li      a7, 93
    la      s0, data

    # 1: multiply result used by the very next instructions (forwarding)
    li      a0, 1
    li      t0, 7
    li      t1, -6
    mul     t2, t0, t1
    addi    t3, t2, 0               # from MEM
    addi    t4, t2, 0               # from WB
    li      t5, -42
    bne     t3, t5, fail
    bne     t4, t5, fail

    # 2: divide operands produced right before it (forwarded on its first
    #    cycle; the producers retire while it runs), result used right after
    li      a0, 2
    li      t0, 100
    li      t1, 7
    div     t2, t0, t1
    addi    t3, t2, 1               # needs the divide's result straight away
    li      t5, 15
    bne     t3, t5, fail

    # 3: load feeding a divide (load-use stall, then the divide stall)
    li      a0, 3
    li      t0, -100
    sw      t0, 0(s0)
    li      t1, 7
    lw      t2, 0(s0)
    rem     t3, t2, t1              # -100 rem 7 = -2 (sign of the dividend)
    li      t5, -2
    bne     t3, t5, fail

    # 4: back-to-back divides, the second using the first's result
    li      a0, 4
    li      t0, 1000
    li      t1, 10
    divu    t2, t0, t1              # 100
    divu    t3, t2, t1              # 10
    remu    t4, t3, t1              # 0
    li      t5, 10
    bne     t3, t5, fail
    bnez    t4, fail

    # 5: the spec's special cases: divide by zero and overflow
    li      a0, 5
    li      t0, 1234
    div     t1, t0, zero            # -1
    li      t5, -1
    bne     t1, t5, fail
    divu    t1, t0, zero            # all ones
    bne     t1, t5, fail
    rem     t1, t0, zero            # the dividend
    bne     t1, t0, fail
    li      t0, 0x80000000
    li      t2, -1
    div     t1, t0, t2              # -2^31 / -1 = -2^31
    bne     t1, t0, fail
    rem     t1, t0, t2              # remainder 0
    bnez    t1, fail

    # 6: high halves of the product, all sign combinations
    li      a0, 6
    li      t0, -2
    li      t1, 3
    mulh    t2, t0, t1              # -6 >> 32 = -1
    li      t5, -1
    bne     t2, t5, fail
    mulhu   t2, t0, t1              # (2^32 - 2) * 3 >> 32 = 2
    li      t5, 2
    bne     t2, t5, fail
    mulhsu  t2, t1, t0              # 3 * (2^32 - 2) >> 32 = 2
    bne     t2, t5, fail
    mulhsu  t2, t0, t1              # -2 * 3 >> 32 = -1
    li      t5, -1
    bne     t2, t5, fail

    # 7: multiply and divide in the second slot of a pair: they must move to
    #    lane 0 and issue alone; the ALU instruction before them still runs
    li      a0, 7
    li      t0, 9
    li      t1, 4
    .balign 8
    addi    t3, zero, 5             # slot 0
    mul     t2, t0, t1              # slot 1 -> 36
    addi    t4, zero, 6             # slot 0
    div     t6, t0, t1              # slot 1 -> 2
    add     t2, t2, t6              # 38
    add     t2, t2, t3              # 43
    add     t2, t2, t4              # 49
    li      t5, 49
    bne     t2, t5, fail

    # 8: a branch that depends on a divide, in a loop (predicted taken)
    li      a0, 8
    li      t0, 64
    li      t1, 0
    li      t2, 2
1:  divu    t0, t0, t2
    addi    t1, t1, 1
    bnez    t0, 1b                  # 64 32 16 8 4 2 1 0: 7 passes
    li      t5, 7
    bne     t1, t5, fail

    # 9: a divide on the wrong path of a taken branch never runs
    li      a0, 9
    li      t3, 5
    j       2f
    div     t3, t3, zero            # skipped: would make t3 = -1
2:  li      t5, 5
    bne     t3, t5, fail

    # 10: an ALU instruction right behind a divide, reading a register
    #     written just before the divide. Paired with the divide it would read
    #     a stale value: its producer retires while the divide runs, and
    #     forwarding can no longer see it. The divide must issue alone.
    li      a0, 10
    li      t0, 50
    li      t1, 5
    .balign 8
    nop                             # slot 0
    li      t2, 11                  # slot 1: producer
    div     t3, t0, t1              # slot 0
    addi    t4, t2, 1               # slot 1: reads t2
    li      t5, 12
    bne     t4, t5, fail
    li      t5, 10
    bne     t3, t5, fail

    # 11: ECALL with a divide right behind it: the divide must not retire
    li      a0, 0
fail:
    ecall
    div     a0, a0, zero            # would make a0 = -1

    .data
    .align 4
data:
    .word 0, 0, 0, 0
