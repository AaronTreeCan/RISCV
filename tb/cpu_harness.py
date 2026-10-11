"""Helpers for running whole programs on your CPU (Week 6 onward).

How programs talk to the testbench (memory-mapped, outside the 64 KB RAM):
    store to 0x8000_0000  -> end of test. 1 = pass, any other odd value = fail
                             (fail code = value >> 1, the riscv-tests convention)
    store to 0x8000_0004  -> print the low byte as a character

What your top-level (CPU_TOP in the Makefile, e.g. rtl/soc.sv) must provide:
    clk, rst                     inputs, rst synchronous and active high
    a data-store port the harness can watch. Set the three names below
    to match your signal names. The harness samples them on the falling
    edge, which is correct for a single-cycle core. In Stage 2, point them
    at your MEM-stage signals.

How the program gets into memory:
    the Makefile passes +hex=<path> to the simulator. In your memory module:
        initial begin
            string f;
            if ($value$plusargs("hex=%s", f)) $readmemh(f, mem);
        end
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge

# Change these to your signal names (as seen from CPU_TOP)
STORE_ENABLE = "dmem_we"     # 1 during a cycle that performs a store
STORE_ADDR = "dmem_addr"     # byte address of the store
STORE_DATA = "dmem_wdata"    # data being stored

EXIT_ADDR = 0x8000_0000
PUTC_ADDR = 0x8000_0004


async def run_program(dut, max_cycles=200_000):
    """Reset the core, run until the program writes EXIT_ADDR.

    Returns (exit_value, console_text, cycles).
    Raises TimeoutError if the program never exits.
    """
    we = getattr(dut, STORE_ENABLE)
    addr = getattr(dut, STORE_ADDR)
    data = getattr(dut, STORE_DATA)

    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    dut.rst.value = 1
    await ClockCycles(dut.clk, 2)
    await FallingEdge(dut.clk)
    dut.rst.value = 0

    console = []
    for cycle in range(max_cycles):
        await FallingEdge(dut.clk)
        if str(we.value).strip() == "1":   # an X/Z enable counts as "no store"
            a = int(addr.value)
            if a == PUTC_ADDR:
                console.append(chr(int(data.value) & 0xFF))
            elif a == EXIT_ADDR:
                return int(data.value), "".join(console), cycle + 1

    raise TimeoutError(
        f"no write to 0x{EXIT_ADDR:08x} after {max_cycles} cycles. "
        f"Console so far: {''.join(console)!r}"
    )
