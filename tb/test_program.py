"""Runs one program (chosen by `make prog-<name>`) and checks it reports a pass."""

import cocotb

from cpu_harness import run_program


@cocotb.test()
async def program_passes(dut):
    exit_value, console, cycles = await run_program(dut)

    if console:
        dut._log.info("console output:\n%s", console)
    dut._log.info("finished in %d cycles", cycles)

    assert exit_value == 1, (
        f"program reported failure: exit value {exit_value:#x} (fail code {exit_value >> 1})"
    )
