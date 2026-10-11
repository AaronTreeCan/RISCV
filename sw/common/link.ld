/* link.ld - memory layout for the single-cycle core
 *
 * One 64 KB RAM at address 0, holding code and data (unified memory with an
 * instruction port and a data port). The whole image is loaded by $readmemh
 * before reset, so .data needs no copy at startup. The stack grows down from
 * the top of RAM.
 *
 * MMIO (outside RAM): 0x8000_0000 = test exit, 0x8000_0004 = putchar
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 64K
}

SECTIONS
{
    .text : {
        *(.text.start)          /* crt0's _start must be at address 0 */
        *(.text .text.*)
    } > RAM

    .rodata : {
        *(.rodata .rodata.* .srodata .srodata.*)
    } > RAM

    .data : {
        *(.data .data.* .sdata .sdata.*)
    } > RAM

    .bss (NOLOAD) : {
        . = ALIGN(4);
        __bss_start = .;
        *(.bss .bss.* .sbss .sbss.* COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > RAM

    __stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
