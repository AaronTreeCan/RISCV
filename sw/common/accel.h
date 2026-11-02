/* accel.h - driver for the INT8 matrix-multiply accelerator (rtl/accel.sv)
 *
 *   accel_matmul(a, w, out, m, k, n, shift, relu)
 *       out[m][n] = clamp(round(relu(a[m][k] x w[k][n]) >> shift), -128, 127)
 *
 * a, w and out are row-major INT8 arrays, 4-byte aligned. k and n must be
 * multiples of 4; m <= 16, k <= 64, n <= 16 (bigger matrices: split them
 * into tiles in software).
 *
 * Everything goes through ordinary loads and stores: copy the matrices into
 * the accelerator's buffers, write the sizes, start, poll STATUS until done,
 * read the results back.
 */
#ifndef ACCEL_H
#define ACCEL_H

#include <stdint.h>

#define ACCEL_BASE   0x40000000u
#define ACCEL_REG(o) (*(volatile uint32_t *)(ACCEL_BASE + (o)))
#define ACCEL_CTRL   ACCEL_REG(0x00)
#define ACCEL_STATUS ACCEL_REG(0x04)
#define ACCEL_DIMS   ACCEL_REG(0x08)
#define ACCEL_QUANT  ACCEL_REG(0x0C)
#define ACCEL_CYCLES ACCEL_REG(0x10)
#define ACCEL_A      ((volatile uint32_t *)(ACCEL_BASE + 0x1000))
#define ACCEL_W      ((volatile uint32_t *)(ACCEL_BASE + 0x2000))
#define ACCEL_CQ     ((volatile uint32_t *)(ACCEL_BASE + 0x4000))

#define ACCEL_M_MAX 16
#define ACCEL_K_MAX 64      /* row stride of the A buffer, in bytes */
#define ACCEL_N_MAX 16      /* row stride of the W and CQ buffers, in bytes */

#define CYCLE_COUNTER (*(volatile uint32_t *)0x80000008u)

static inline uint32_t cycles_now(void) { return CYCLE_COUNTER; }

/* copy rows x cols bytes into a buffer whose rows are stride bytes apart, a word at a time */
static inline void accel_copy_in(volatile uint32_t *dst, const int8_t *src,
                                 int rows, int cols, int stride)
{
    const uint32_t *s = (const uint32_t *)src;
    for (int r = 0; r < rows; r++) {
        volatile uint32_t *d = dst + r * (stride / 4);
        for (int c = 0; c < cols / 4; c++)
            d[c] = *s++;
    }
}

static inline void accel_matmul(const int8_t *a, const int8_t *w, int8_t *out,
                                int m, int k, int n, int shift, int relu)
{
    accel_copy_in(ACCEL_A, a, m, k, ACCEL_K_MAX);
    accel_copy_in(ACCEL_W, w, k, n, ACCEL_N_MAX);
    ACCEL_DIMS  = (uint32_t)m | ((uint32_t)k << 8) | ((uint32_t)n << 16);
    ACCEL_QUANT = (uint32_t)shift | (relu ? 0x100u : 0u);
    ACCEL_CTRL  = 1;
    while (ACCEL_STATUS & 1)
        ;
    uint32_t *o = (uint32_t *)out;
    for (int r = 0; r < m; r++)
        for (int c = 0; c < n / 4; c++)
            *o++ = ACCEL_CQ[r * (ACCEL_N_MAX / 4) + c];
}

#endif
