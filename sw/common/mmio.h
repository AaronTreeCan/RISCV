/* mmio.h - talking to the testbench from C */
#ifndef MMIO_H
#define MMIO_H

#define MMIO_EXIT ((volatile unsigned int *)0x80000000u)
#define MMIO_PUTC ((volatile unsigned int *)0x80000004u)

static inline void mmio_putc(char c) { *MMIO_PUTC = (unsigned char)c; }

static inline void mmio_puts(const char *s)
{
    while (*s) {
        mmio_putc(*s++);
    }
}

#endif
