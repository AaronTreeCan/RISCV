/* bench.c - a small mixed workload with known answers
 *
 * Exercises what the pipeline cares about: dependent arithmetic, loads right
 * before their use, loops (taken branches), function calls and returns.
 * The testbench prints the cycle count and CPI when it finishes.
 * Returns 0 on success, otherwise the number of the check that failed.
 */
#include "mmio.h"

static unsigned crc32(const unsigned char *p, int n)
{
    unsigned crc = 0xFFFFFFFFu;
    for (int i = 0; i < n; i++) {
        crc ^= p[i];
        for (int b = 0; b < 8; b++)
            crc = (crc >> 1) ^ (0xEDB88320u & -(crc & 1u));
    }
    return ~crc;
}

static void sort(int *a, int n)          /* insertion sort */
{
    for (int i = 1; i < n; i++) {
        int v = a[i], j = i - 1;
        while (j >= 0 && a[j] > v) {
            a[j + 1] = a[j];
            j--;
        }
        a[j + 1] = v;
    }
}

static unsigned fib(unsigned n)
{
    return n < 2 ? n : fib(n - 1) + fib(n - 2);
}

static int arr[32];

int main(void)
{
    static const char msg[] = "123456789";
    if (crc32((const unsigned char *)msg, 9) != 0xCBF43926u) return 1;  /* standard check value */

    unsigned x = 12345;
    for (int i = 0; i < 32; i++) {          /* xorshift, values in -500..499 */
        x ^= x << 13; x ^= x >> 17; x ^= x << 5;
        arr[i] = (int)(x % 1000u) - 500;
    }
    sort(arr, 32);
    for (int i = 1; i < 32; i++)
        if (arr[i - 1] > arr[i]) return 2;

    if (fib(15) != 610) return 3;

    mmio_puts("bench ok\n");
    return 0;
}
