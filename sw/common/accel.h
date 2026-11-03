/* accel.h - driver for the INT8 matrix-multiply accelerator (rtl/accel.sv)
 *
 *   accel_matmul(a, w, out, m, k, n, shift, relu)
 *       out[m][n] = clamp(round(relu(a[m][k] x w[k][n]) >> shift), -128, 127)
 *
 * a, w and out are row-major INT8 arrays, 4-byte aligned. k and n must be
 * multiples of 4; m <= 16, k <= 64, n <= 16 (bigger matrices: split them
 * into tiles in software).
 *
 * The DMA engine (rtl/dma.sv) copies the matrices into the accelerator's
 * buffers and the results back out; the core only writes descriptors and
 * polls. accel_matmul_cpu() does the same with the core's own loads and
 * stores, for comparison.
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

#define DMA_BASE       0x50000000u
#define DMA_REG(o)     (*(volatile uint32_t *)(DMA_BASE + (o)))
#define DMA_SRC        DMA_REG(0x00)
#define DMA_DST        DMA_REG(0x04)
#define DMA_ROW_BYTES  DMA_REG(0x08)
#define DMA_ROWS       DMA_REG(0x0C)
#define DMA_SRC_STRIDE DMA_REG(0x10)
#define DMA_DST_STRIDE DMA_REG(0x14)
#define DMA_CTRL       DMA_REG(0x18)
#define DMA_STATUS     DMA_REG(0x1C)

/* copy rows x row_bytes bytes; each side has its own row stride. Waits until done. */
static inline void dma_copy(uint32_t dst, int dst_stride, uint32_t src, int src_stride,
                            int rows, int row_bytes)
{
    DMA_SRC        = src;
    DMA_DST        = dst;
    DMA_ROW_BYTES  = (uint32_t)row_bytes;
    DMA_ROWS       = (uint32_t)rows;
    DMA_SRC_STRIDE = (uint32_t)src_stride;
    DMA_DST_STRIDE = (uint32_t)dst_stride;
    DMA_CTRL       = 1;
    while (DMA_STATUS & 1)
        ;
}

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

static inline void accel_run(int m, int k, int n, int shift, int relu)
{
    ACCEL_DIMS  = (uint32_t)m | ((uint32_t)k << 8) | ((uint32_t)n << 16);
    ACCEL_QUANT = (uint32_t)shift | (relu ? 0x100u : 0u);
    ACCEL_CTRL  = 1;
    while (ACCEL_STATUS & 1)
        ;
}

/* the matrices move with the DMA */
static inline void accel_matmul(const int8_t *a, const int8_t *w, int8_t *out,
                                int m, int k, int n, int shift, int relu)
{
    dma_copy((uint32_t)ACCEL_A, ACCEL_K_MAX, (uint32_t)a, k, m, k);
    dma_copy((uint32_t)ACCEL_W, ACCEL_N_MAX, (uint32_t)w, n, k, n);
    accel_run(m, k, n, shift, relu);
    dma_copy((uint32_t)out, n, (uint32_t)ACCEL_CQ, ACCEL_N_MAX, m, n);
}

/* the same, with the core copying (loads and stores in a loop) */
static inline void accel_matmul_cpu(const int8_t *a, const int8_t *w, int8_t *out,
                                    int m, int k, int n, int shift, int relu)
{
    accel_copy_in(ACCEL_A, a, m, k, ACCEL_K_MAX);
    accel_copy_in(ACCEL_W, w, k, n, ACCEL_N_MAX);
    accel_run(m, k, n, shift, relu);
    uint32_t *o = (uint32_t *)out;
    for (int r = 0; r < m; r++)
        for (int c = 0; c < n / 4; c++)
            *o++ = ACCEL_CQ[r * (ACCEL_N_MAX / 4) + c];
}

#endif
