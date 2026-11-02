# rv32i-core - top-level build
#
#   make test            run every unit test listed in UNIT_TESTS
#   make test-alu        run one unit test (rtl/alu.sv + tb/tb_alu.sv), Icarus by default
#   make test-alu SIM=verilator   same test on Verilator 5
#   make waves-alu       same, but also dump a .vcd waveform for GTKWave
#   make prog-hello      compile sw/c/hello.c, run it on the dual-issue core, checked
#                        instruction by instruction against the single-cycle core
#   make prog-hello CORE=1   same on the 5-stage scalar pipeline (CORE=0: single-cycle)
#   make prog-hello PLUSARGS=+waves   same, plus build/sim/prog-hello/tb_soc.vcd
#   make isa             run the official rv32ui + rv32um tests (third_party/riscv-tests)
#   make lint            Verilator lint on every rtl/*.sv file
#   make synth           Yosys synthesis of SYNTH_TOP; fails if a latch is inferred
#   make synth SYNTH_TOP=systolic   same for the accelerator's systolic array
#   make fmax            place and route CORE on a Lattice ECP5 (nextpnr), report the max clock
#                        (median of 5 placements; LATE_REDIRECT=0 for the old redirect)
#   make clean           delete build outputs
#
# Add a block: create rtl/<name>.sv and tb/tb_<name>.sv, then add <name> below.
# A testbench passes by printing "TEST PASSED"; on failure it calls $fatal.

UNIT_TESTS ?= alu regfile decoder branch_cmp muldiv accel

# Module to synthesize: a CPU without its RAM (a 64 KB array of flip-flops
# would swamp the numbers; real chips use SRAM macros). core = 5-stage pipeline.
SYNTH_TOP ?= core_dual

SIM ?= icarus

# Core that prog-* and isa run (see rtl/soc.sv): 0 single-cycle, 1 pipeline, 2 dual-issue
CORE ?= 2

export SIM CORE

.PHONY: test isa lint synth fmax clean
.SECONDEXPANSION:     # lets test-% depend on $(call SIM_BIN,<name>)
.SECONDARY:           # keep compiled simulators between runs

test: $(addprefix test-,$(UNIT_TESTS))
	@echo "All unit tests passed: $(UNIT_TESTS)"

PKGS := $(wildcard rtl/*_pkg.sv)
SRCS := $(PKGS) $(filter-out $(PKGS),$(wildcard rtl/*.sv))

# Simulator binary for tb/tb_<name>.sv. Make rebuilds it only when the RTL or
# the testbench changes, so running many programs compiles the SoC once.
ifeq ($(SIM),verilator)
SIM_BIN = build/sim/$(1)/obj/Vtb
SIM_RUN = build/sim/$(1)/obj/Vtb
else
SIM_BIN = build/sim/$(1)/tb.vvp
SIM_RUN = vvp -n build/sim/$(1)/tb.vvp
endif

# (Icarus prints a harmless "sorry: constant selects" note per struct field; hidden)
build/sim/%/tb.vvp: $(SRCS) tb/tb_%.sv
	@mkdir -p $(@D) && rm -f $@
	@iverilog -g2012 -Wno-sensitivity-entire-array -o $@ $^ 2>&1 | grep -v "sorry: constant selects" || true
	@test -f $@

# The program harness is built once per core: build/sim/soc_c<CORE>/
build/sim/soc_c%/tb.vvp: $(SRCS) tb/tb_soc.sv
	@mkdir -p $(@D) && rm -f $@
	@iverilog -g2012 -Wno-sensitivity-entire-array -Ptb_soc.CORE=$* -o $@ $^ 2>&1 | grep -v "sorry: constant selects" || true
	@test -f $@

build/sim/soc_c%/obj/Vtb: $(SRCS) tb/tb_soc.sv
	@mkdir -p $(@D)
	@verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style --top-module tb_soc -GCORE=$* \
		-Mdir $(@D) -o Vtb $^ > build/sim/soc_c$*/build.log 2>&1 \
		|| (cat build/sim/soc_c$*/build.log; exit 1)

build/sim/%/obj/Vtb: $(SRCS) tb/tb_%.sv
	@mkdir -p $(@D)
	@verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style --top-module tb_$* \
		-Mdir $(@D) -o Vtb $^ > build/sim/$*/build.log 2>&1 \
		|| (cat build/sim/$*/build.log; exit 1)

# run-sim <tb name> <log dir> <plusargs>: pass only if the log says "TEST PASSED"
# and no assertion fired ($error prints "ERROR:" on Icarus, "%Error" on Verilator)
define run-sim
	@mkdir -p $(2)
	@$(call SIM_RUN,$(1)) $(3) | tee $(2)/sim.log
	@grep -q "TEST PASSED" $(2)/sim.log
	@! grep -Eq "^(ERROR|%Error)" $(2)/sim.log || { echo "FAIL: assertion error in $(2)/sim.log"; exit 1; }
endef

# Unit tests: self-checking SystemVerilog testbenches (tb/tb_<name>.sv)
test-%: $$(call SIM_BIN,$$*)
	$(call run-sim,$*,build/sim/$*,$(PLUSARGS))

waves-%:
	@$(MAKE) --no-print-directory test-$* SIM=icarus PLUSARGS=+waves
	@echo "Waveform: gtkwave build/sim/$*/tb_$*.vcd"

# Programs: build sw/c/<name>.c or sw/asm/<name>.S, run it on the SoC (tb/tb_soc.sv)
# with core CORE, checked against the single-cycle core
prog-%: $(call SIM_BIN,soc_c$(CORE))
	@$(MAKE) --no-print-directory -C sw build/$*.hex RISCV_TESTS=$(abspath $(RISCV_TESTS))
	$(call run-sim,soc_c$(CORE),build/sim/c$(CORE)/prog-$*,+hex=$(CURDIR)/sw/build/$*.hex \
		+wavefile=$(CURDIR)/build/sim/c$(CORE)/prog-$*/tb_soc.vcd $(PLUSARGS))

# Official RISC-V ISA tests (git submodule), one program per instruction:
# rv32ui (base integer) and rv32um (multiply/divide).
#   fence_i: needs Zifencei (FENCE.I), not implemented
#   ma_data: needs misaligned loads/stores, which this core reports as errors
RISCV_TESTS ?= third_party/riscv-tests
ISA_TESTS ?= $(addprefix rv32ui-,$(filter-out fence_i ma_data, \
	$(basename $(notdir $(wildcard $(RISCV_TESTS)/isa/rv32ui/*.S))))) \
	$(addprefix rv32um-,$(basename $(notdir $(wildcard $(RISCV_TESTS)/isa/rv32um/*.S))))

isa: $(call SIM_BIN,soc_c$(CORE))
	@test -d $(RISCV_TESTS)/isa || { echo "missing $(RISCV_TESTS): run git submodule update --init"; exit 1; }
	@pass=0; failed=""; \
	for t in $(ISA_TESTS); do \
		if $(MAKE) --no-print-directory prog-$$t PLUSARGS=+max_cycles=20000 > build/isa-c$(CORE)-$$t.log 2>&1; then \
			pass=$$((pass+1)); echo "PASS  $$t"; \
		else \
			failed="$$failed $$t"; echo "FAIL  $$t   (log: build/isa-c$(CORE)-$$t.log)"; \
		fi; \
	done; \
	echo "rv32ui + rv32um on core $(CORE): $$pass/$(words $(ISA_TESTS)) passed"; \
	test -z "$$failed"

lint:
	@for f in $(filter-out $(PKGS),$(wildcard rtl/*.sv)); do \
		echo "lint $$f"; \
		verilator --lint-only -Wall -Wno-UNUSEDPARAM -Irtl $(PKGS) $$f || exit 1; \
	done

# Yosys's built-in parser can't read SV packages/imports, so sv2v converts
# rtl/*.sv to plain Verilog first.
synth:
	@mkdir -p build
	@sv2v -DSYNTHESIS $(SRCS) > build/synth.v
	@yosys -q -l build/synth.log -p "read_verilog build/synth.v; synth -top $(strip $(SYNTH_TOP)); tee -q -o build/synth_stat.txt stat" >/dev/null
	@cat build/synth_stat.txt
	@if grep -i "latch inferred" build/synth.log | grep -vqi "no latch inferred"; then \
		echo "ERROR: latch inferred - see build/synth.log"; \
		grep -i "latch inferred" build/synth.log | grep -vi "no latch inferred"; exit 1; \
	fi
	@echo "Synthesis OK, no latches (full log: build/synth.log)"

# Maximum clock frequency on a real FPGA (Lattice ECP5-85F), for CORE 1 or 2.
# fpga/fmax_top.sv puts flip-flops on every core input and output, so this
# measures the core's own paths (memories excluded).
# Placement is randomized and the result moves by a few MHz from run to run,
# so it is placed 5 times (seeds 1-5, in parallel) and the median is reported.
# The slowest path is in build/fmax/pnr-<seed>.log ("Critical path report").
# LATE_REDIRECT=0 measures the dual-issue core with the old same-cycle
# branch redirect.
LATE_REDIRECT ?= 1
FMAX_SEEDS    ?= 1 2 3 4 5
fmax:
	@mkdir -p build/fmax
	@sv2v -DSYNTHESIS $(SRCS) fpga/fmax_top.sv > build/fmax/fmax.v
	@yosys -q -l build/fmax/synth.log -p "read_verilog build/fmax/fmax.v; chparam -set CORE $(CORE) fmax_top; \
		$(if $(filter 2,$(CORE)),chparam -set LATE_REDIRECT $(LATE_REDIRECT) core_dual;) \
		synth_ecp5 -top fmax_top -json build/fmax/fmax.json" >/dev/null
	@for s in $(FMAX_SEEDS); do \
		nextpnr-ecp5 --85k --package CABGA381 --json build/fmax/fmax.json --freq 50 --seed $$s \
			--lpf-allow-unconstrained --timing-allow-fail > build/fmax/pnr-$$s.log 2>&1 & \
	done; wait
	@grep -E "Total LUT4s|MULT18X18D|TRELLIS_FF" build/fmax/pnr-$(firstword $(FMAX_SEEDS)).log | head -3
	@for s in $(FMAX_SEEDS); do grep "Max frequency" build/fmax/pnr-$$s.log | tail -1 | grep -o "[0-9.]* MHz" | head -1; done \
		| sort -n | awk '{v[NR]=$$1} END {printf "core $(CORE): max clock %.1f MHz (median of %d placements, range %.1f-%.1f)\n", \
		  v[int((NR+1)/2)], NR, v[1], v[NR]}'

clean:
	rm -rf build sw/build
