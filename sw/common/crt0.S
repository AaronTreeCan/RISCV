/* crt0.S - C runtime startup for the RV32I core
 *
 * Runs from address 0 after reset:
 *   1. set the stack pointer to the top of RAM
 *   2. zero .bss
 *   3. call main()
 *   4. report main's return value to the testbench:
 *        return 0  -> store 1 to EXIT (pass)
 *        return n  -> store (n << 1) | 1 to EXIT (fail code n)
 *   5. spin forever
 */

    .section .text.start
    .globl _start
_start:
    la      sp, __stack_top

    la      t0, __bss_start
    la      t1, __bss_end
1:  bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:
    call    main

    li      t0, 0x80000000      /* EXIT address */
    li      t1, 1
    beqz    a0, 3f
    slli    t1, a0, 1
    ori     t1, t1, 1
3:  sw      t1, 0(t0)
4:  j       4b
