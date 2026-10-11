# rv32i-core

<!-- One sentence a recruiter reads in 5 seconds. Update it at each milestone. -->
A single-cycle RISC-V (RV32I) processor in SystemVerilog, verified with cocotb, that runs compiled C. **Status: in progress (Stage 1).**

<!-- Week 8: put your datapath diagram here -->
<!-- ![Datapath](docs/diagrams/datapath.svg) -->

## Results

<!-- Fill in as you go. Numbers beat adjectives. -->

| | |
| --- | --- |
| ISA | RV32I (_ of 40 instructions) |
| Microarchitecture | Single-cycle |
| riscv-tests (rv32ui-p) | _ / _ passing |
| Unit tests | ALU, register file, decoder, immediate generator, ... |
| Synthesis (Yosys) | _ cells |
| C programs | hello, CRC32, ... |

## Design highlights

<!-- 3-5 bullets, each linking to the decision in docs/design-notes.md. Example:
- Main decoder and ALU decoder split for readability ([why](docs/design-notes.md#...))
-->

## Repository layout

```
rtl/         SystemVerilog design (one module per file)
tb/          cocotb testbenches (test_<module>.py) and the CPU program harness
sw/          programs that run on the core: c/, asm/, common/ (crt0, linker script)
scripts/     helpers (results checker, bin -> hex)
docs/        design notes, bug log, encoding table, diagrams, progress log
```

## Running it

Requires Icarus Verilog, Python 3.10+, and `pip install -r requirements.txt`.
Yosys for `make synth`, Verilator for `make lint`, and a RISC-V GCC (`riscv64-unknown-elf-gcc`) for programs.

```
make test          # all unit tests
make test-alu      # one block
make waves-alu     # same, plus a waveform for GTKWave
make prog-hello    # compile sw/c/hello.c and run it on the core
make synth         # Yosys synthesis, fails if a latch is inferred
```

## Verification

<!-- How you know it works: unit tests with random inputs vs a Python model,
     self-checking assembly tests, riscv-tests, C programs. Link the bug log. -->

## Roadmap

- [ ] Stage 1: single-cycle RV32I
- [ ] Stage 2: 5-stage pipeline with forwarding and hazard detection
- [ ] Stage 3: in-order dual-issue superscalar
