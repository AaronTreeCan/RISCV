/* mlp.c - a two-layer neural net: in software, on the accelerator with the
 * core copying the data, and on the accelerator with the DMA copying it
 *
 *   x  (16 x 64)  --[ W1 64 x 16, ReLU ]-->  h (16 x 16)  --[ W2 16 x 16 ]-->  y (16 x 16)
 *
 * 16 inputs (a batch) of 64 features each. All values are INT8; each layer
 * multiplies into INT32 sums, then requantizes back to INT8 (round, shift,
 * clamp), like a quantized network on a phone or microcontroller. The weights
 * are pseudo-random, not trained: the point is the arithmetic, which must be
 * bit-exact between the two versions.
 *
 * Prints the cycle count of each version and the speedups. Returns 0 if both
 * accelerator versions match the software exactly.
 */
#include <stdint.h>
#include "mmio.h"
#include "accel.h"

#define B   16      /* batch */
#define IN  64
#define HID 16
#define OUT 16

static int8_t x[B * IN]     __attribute__((aligned(4)));
static int8_t w1[IN * HID]  __attribute__((aligned(4)));
static int8_t w2[HID * OUT] __attribute__((aligned(4)));
static int8_t h_sw[B * HID] __attribute__((aligned(4)));
static int8_t y_sw[B * OUT] __attribute__((aligned(4)));
static int8_t h_hw[B * HID] __attribute__((aligned(4)));
static int8_t y_hw[B * OUT] __attribute__((aligned(4)));
static int8_t h_cp[B * HID] __attribute__((aligned(4)));
static int8_t y_cp[B * OUT] __attribute__((aligned(4)));

static int8_t requant(int32_t acc, int shift, int relu)     /* same as the hardware */
{
    if (relu && acc < 0) acc = 0;
    if (shift > 0) acc = (acc + (1 << (shift - 1))) >> shift;
    if (acc > 127) return 127;
    if (acc < -128) return -128;
    return (int8_t)acc;
}

static void matmul_sw(const int8_t *a, const int8_t *w, int8_t *out,
                      int m, int k, int n, int shift, int relu)
{
    for (int i = 0; i < m; i++)
        for (int j = 0; j < n; j++) {
            int32_t acc = 0;
            for (int t = 0; t < k; t++)
                acc += a[i * k + t] * w[t * n + j];
            out[i * n + j] = requant(acc, shift, relu);
        }
}

static void fill(int8_t *p, int len, uint32_t *seed)
{
    for (int i = 0; i < len; i++) {
        uint32_t s = *seed;
        s ^= s << 13; s ^= s >> 17; s ^= s << 5;
        *seed = s;
        p[i] = (int8_t)(s >> 24);
    }
}

static void put_uint(uint32_t v)
{
    char buf[11];
    int i = 10;
    buf[i] = 0;
    do {
        buf[--i] = (char)('0' + v % 10);
        v /= 10;
    } while (v);
    mmio_puts(&buf[i]);
}

static void put_speedup(uint32_t sw, uint32_t hw)
{
    put_uint(sw / hw); mmio_puts(".");
    put_uint((sw * 10 / hw) % 10); mmio_puts("x faster than software\n");
}

int main(void)
{
    uint32_t seed = 2024;
    fill(x, B * IN, &seed);
    fill(w1, IN * HID, &seed);
    fill(w2, HID * OUT, &seed);

    uint32_t t0 = cycles_now();
    matmul_sw(x, w1, h_sw, B, IN, HID, 10, 1);
    matmul_sw(h_sw, w2, y_sw, B, HID, OUT, 8, 0);
    uint32_t t1 = cycles_now();
    accel_matmul_cpu(x, w1, h_cp, B, IN, HID, 10, 1);
    accel_matmul_cpu(h_cp, w2, y_cp, B, HID, OUT, 8, 0);
    uint32_t t2 = cycles_now();
    accel_matmul(x, w1, h_hw, B, IN, HID, 10, 1);
    uint32_t busy1 = ACCEL_CYCLES;
    accel_matmul(h_hw, w2, y_hw, B, HID, OUT, 8, 0);
    uint32_t busy2 = ACCEL_CYCLES;
    uint32_t t3 = cycles_now();

    for (int i = 0; i < B * HID; i++)
        if (h_hw[i] != h_sw[i] || h_cp[i] != h_sw[i]) return 1;
    for (int i = 0; i < B * OUT; i++)
        if (y_hw[i] != y_sw[i] || y_cp[i] != y_sw[i]) return 2;

    /* a layer where most outputs clamp would hide bugs; make sure they vary */
    static uint8_t seen[256];
    int distinct = 0;
    for (int i = 0; i < B * OUT; i++) {
        uint8_t v = (uint8_t)y_sw[i];
        if (!seen[v]) { seen[v] = 1; distinct++; }
    }
    if (distinct < 20) return 3;

    uint32_t sw = t1 - t0, cp = t2 - t1, hw = t3 - t2;
    mmio_puts("mlp: software                 "); put_uint(sw); mmio_puts(" cycles\n");
    mmio_puts("mlp: accelerator, core copies "); put_uint(cp); mmio_puts(" cycles, ");
    put_speedup(sw, cp);
    mmio_puts("mlp: accelerator, DMA copies  "); put_uint(hw); mmio_puts(" cycles, ");
    put_speedup(sw, hw);
    mmio_puts("mlp: array busy "); put_uint(busy1 + busy2); mmio_puts(" cycles; outputs match\n");
    return 0;
}
