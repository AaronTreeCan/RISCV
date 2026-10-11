#!/usr/bin/env python3
"""Convert a raw binary (from objcopy -O binary) to a $readmemh file.

One 32-bit little-endian word per line, so word N of the file is memory
address 4*N. Your memory should be a word array, e.g.
    logic [31:0] mem [0:16383];   // 64 KB
"""

import sys


def main(src: str, dst: str) -> None:
    data = open(src, "rb").read()
    data += b"\x00" * (-len(data) % 4)
    with open(dst, "w") as f:
        for i in range(0, len(data), 4):
            f.write(f"{int.from_bytes(data[i:i + 4], 'little'):08x}\n")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: bin2hex.py <in.bin> <out.hex>")
        sys.exit(2)
    main(sys.argv[1], sys.argv[2])
