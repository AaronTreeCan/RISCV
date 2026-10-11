/* hello.c - first C program for your core (Week 7). Run with: make prog-hello */
#include "mmio.h"

int main(void)
{
    mmio_puts("hello from my RV32I core\n");
    return 0; /* 0 = pass */
}
