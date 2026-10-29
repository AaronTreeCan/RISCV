// riscv_test.h - minimal test environment for running the official
// riscv-tests (isa/rv32ui) on this core.
//
// The stock "p" environment sets up machine-mode CSRs and trap handlers,
// which this core doesn't have. The tests only need four things from the
// environment: where code starts, how to report pass, how to report fail,
// and where data goes. Results use the riscv-tests convention:
//   pass: a7 = 93, a0 = 0, then ECALL
//   fail: a7 = 93, a0 = (failing test number << 1) | 1, then ECALL
// tb/tb_soc.sv checks a7/a0 when the core halts on ECALL.

#ifndef RISCV_TEST_H
#define RISCV_TEST_H

#define RVTEST_RV32U .macro init; .endm
#define RVTEST_RV64U RVTEST_RV32U

#define TESTNUM gp

#define RVTEST_CODE_BEGIN       \
    .section .text.start;       \
    .globl _start;              \
_start:                         \
    li TESTNUM, 0;

#define RVTEST_CODE_END unimp

#define RVTEST_PASS             \
    li TESTNUM, 1;              \
    li a7, 93;                  \
    li a0, 0;                   \
    ecall

#define RVTEST_FAIL             \
1:  beqz TESTNUM, 1b;           \
    sll TESTNUM, TESTNUM, 1;    \
    or TESTNUM, TESTNUM, 1;     \
    li a7, 93;                  \
    addi a0, TESTNUM, 0;        \
    ecall

#define EXTRA_DATA
#define RVTEST_DATA_BEGIN EXTRA_DATA .align 4; .global begin_signature; begin_signature:
#define RVTEST_DATA_END .align 4; .global end_signature; end_signature:

#endif
