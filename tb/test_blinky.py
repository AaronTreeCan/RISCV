"""cocotb tests for rtl/blinky.sv - the example to copy when testing your own blocks.

Every test file follows the same shape:
  1. start a clock
  2. apply reset
  3. drive inputs on the falling edge, check outputs on the falling edge
     (halfway through the cycle, so everything has settled)
  4. assert with a message that says what you expected and what you got
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge

HALF_PERIOD = 4  # must match the RTL parameter default


async def start_and_reset(dut, cycles=2):
    """Start a 100 MHz clock and hold reset for `cycles` cycles."""
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    dut.rst.value = 1
    await ClockCycles(dut.clk, cycles)
    await FallingEdge(dut.clk)
    dut.rst.value = 0


@cocotb.test()
async def led_low_during_reset(dut):
    """While reset is held, the LED must stay off."""
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    dut.rst.value = 1
    for _ in range(3 * HALF_PERIOD):
        await FallingEdge(dut.clk)
        assert int(dut.led.value) == 0, "LED changed while reset was held"


@cocotb.test()
async def led_toggles_every_half_period(dut):
    """After reset, the LED flips exactly every HALF_PERIOD cycles."""
    await start_and_reset(dut)

    samples = []
    for _ in range(8 * HALF_PERIOD):
        await FallingEdge(dut.clk)
        samples.append(int(dut.led.value))

    changes = [i for i in range(1, len(samples)) if samples[i] != samples[i - 1]]
    assert len(changes) >= 3, f"LED barely toggled: {samples}"

    gaps = {b - a for a, b in zip(changes, changes[1:])}
    assert gaps == {HALF_PERIOD}, (
        f"expected a toggle every {HALF_PERIOD} cycles, saw gaps {sorted(gaps)}: {samples}"
    )
