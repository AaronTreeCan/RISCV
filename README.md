# rv32i-core

A single-cycle RISC-V (RV32I) processor in SystemVerilog, verified with self-checking SystemVerilog testbenches and the official riscv-tests, that runs compiled C. **Status: in progress (Stage 1).**

<!-- datapath diagram here -->
<!-- ![Datapath](docs/diagrams/datapath.svg) -->

## Results

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
tb/          self-checking SV testbenches (tb_<module>.sv) and the program harness (tb_soc.sv)
sw/          programs that run on the core: c/, asm/, common/ (crt0, linker script), isa/ (riscv-tests env)
third_party/ riscv-tests (git submodule)
scripts/     helpers (bin -> hex)
docs/        design notes, bug log, encoding table, diagrams, progress log
```

## Running it

Requires Icarus Verilog 12 or Verilator 5, a RISC-V GCC (`riscv64-unknown-elf-gcc`) for programs,
and Yosys + sv2v for `make synth`. Clone with `git clone --recursive` (or run
`git submodule update --init`) to get riscv-tests.

```
make test          # all unit tests
make test-alu      # one block
make waves-alu     # same, plus a waveform for GTKWave
make prog-hello    # compile sw/c/hello.c and run it on the core
make isa           # official rv32ui riscv-tests
make test SIM=verilator   # any of the above on Verilator instead of Icarus
make synth         # Yosys synthesis, fails if a latch is inferred
```

## Verification

<!-- How you know it works: unit tests with random inputs vs a Python model,
     self-checking assembly tests, riscv-tests, C programs. Link the bug log. -->

## Roadmap

- [ ] Stage 1: single-cycle RV32I
- [ ] Stage 2: 5-stage pipeline with forwarding and hazard detection
- [ ] Stage 3: in-order dual-issue superscalar
