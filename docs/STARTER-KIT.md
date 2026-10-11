# Starter kit guide

What's in this repo before you write any RTL, how the pieces fit, and what to do when something breaks.
Delete this file once you're comfortable; it isn't part of your portfolio.

## What the kit gives you, and what it doesn't

| Provided | You write |
| --- | --- |
| Build and test commands (`Makefile`, `tb/cocotb.mk`) | Every module in `rtl/` (ALU, register file, decoder, core, memory) |
| `rtl/blinky.sv` + `tb/test_blinky.py`, an example to copy the pattern from | Every `tb/test_<module>.py` for your blocks |
| `tb/cpu_harness.py`: runs a program, captures putchar, detects exit | The assembly tests in `sw/asm/` |
| `sw/common/`: crt0, linker script, MMIO header | Your C programs beyond `hello.c` |
| CI, `.gitignore`, documentation templates | All design decisions |

## Week 0 setup

1. Install the tools (see the curriculum doc). Quickest: OSS CAD Suite from YosysHQ, which includes Icarus, Verilator, Yosys and GTKWave. On Windows, do everything inside WSL2.
2. Create a Python virtual environment and install cocotb:
   ```
   python3 -m venv .venv
   source .venv/bin/activate
   pip install -r requirements.txt
   ```
3. Run the example:
   ```
   make test          # expect: "2/2 tests passed" and "All unit tests passed: blinky"
   make waves-blinky  # then open the .fst file in build/sim/blinky/ with GTKWave
   make synth         # expect a cell count and "Synthesis OK, no latches"
   ```
4. Put it on GitHub:
   ```
   git init -b main
   git add .
   git commit -m "Initial commit: starter kit"
   git remote add origin https://github.com/<you>/rv32i-core.git
   git push -u origin main
   ```
   Open the Actions tab and check that the CI run turns green.

## Adding a block (the loop you'll repeat all of Stage 1)

1. Write `rtl/<name>.sv`.
2. Write `tb/test_<name>.py`, copying the shape of `tb/test_blinky.py`.
3. Add `<name>` to `UNIT_TESTS` in the `Makefile`.
4. `make test-<name>` until it passes, then `make test` and `make synth`.
5. Commit, and update `docs/progress.md`.

## Running programs (Week 6 onward)

`make prog-<name>` compiles `sw/c/<name>.c` (or `sw/asm/<name>.S`), loads it into your memory, and runs it on `CPU_TOP` until it writes the exit address. Before it works:

- Set `CPU_TOP` in the `Makefile` to your top-level module (core + memory).
- Edit the three signal names at the top of `tb/cpu_harness.py` to match your data-store port.
- Load memory from the `+hex=` plusarg (`tb/cpu_harness.py` shows the four lines to add).
- Assembly tests must define `_start` and end by storing 1 (pass) to `0x8000_0000`.

Memory map: one 64 KB RAM at `0x0000_0000`, stack at the top, `0x8000_0000` = exit, `0x8000_0004` = putchar.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| `cocotb-config: command not found` | Virtual environment not active: `source .venv/bin/activate` |
| `FAIL: no test results ... Did the RTL compile?` | Syntax error in some `rtl/*.sv` (all files compile together); scroll up for the iverilog error |
| Icarus rejects valid-looking SystemVerilog | Icarus supports a subset of SV. Try `make test-<name> SIM=verilator` (needs Verilator 5.x) |
| Every output is `x` in the waveform | Reset not applied, or a register missing from the reset branch |
| `ERROR: latch inferred` from `make synth` | An `always_comb` output isn't assigned on every path; add a default at the top of the block |
| No `.fst` file after `make waves-<name>` | Older cocotb versions name it differently; look for any `.fst` or `.vcd` in `build/sim/<name>/` |
| `undefined reference to memset` / `memcpy` | GCC emitted a library call; write your own in `sw/common/` and add it to the C rule in `sw/Makefile` |
| `cannot find -lgcc` | Your toolchain lacks an rv32i multilib; use the xPack RISC-V GCC prebuilt release instead |
