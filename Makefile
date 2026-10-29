# rv32i-core - top-level build
#
#   make test            run every unit test listed in UNIT_TESTS
#   make test-alu        run one unit test (rtl/alu.sv + tb/tb_alu.sv), Icarus by default
#   make test-alu SIM=verilator   same test on Verilator 5
#   make waves-alu       same, but also dump a .vcd waveform for GTKWave
#   make prog-hello      compile sw/c/hello.c, run it on the CPU (tb/tb_soc.sv)
#   make prog-hello PLUSARGS=+waves   same, plus build/sim/prog-hello/tb_soc.vcd
#   make isa             run the official rv32ui tests (third_party/riscv-tests)
#   make lint            Verilator lint on every rtl/*.sv file
#   make synth           Yosys synthesis of SYNTH_TOP; fails if a latch is inferred
#   make clean           delete build outputs
#
# Add a block: create rtl/<name>.sv and tb/tb_<name>.sv, then add <name> below.
# A testbench passes by printing "TEST PASSED"; on failure it calls $fatal.

UNIT_TESTS ?= alu regfile decoder branch_cmp

# Module to synthesize. core = the CPU without its RAM (a 64 KB array of
# flip-flops would swamp the numbers; real chips use SRAM macros).
SYNTH_TOP ?= core

SIM ?= icarus

export SIM

.PHONY: test isa lint synth clean
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
prog-%: $(call SIM_BIN,soc)
	@$(MAKE) --no-print-directory -C sw build/$*.hex RISCV_TESTS=$(abspath $(RISCV_TESTS))
	$(call run-sim,soc,build/sim/prog-$*,+hex=$(CURDIR)/sw/build/$*.hex \
		+wavefile=$(CURDIR)/build/sim/prog-$*/tb_soc.vcd $(PLUSARGS))

# Official RISC-V ISA tests (git submodule), one program per instruction.
#   fence_i: needs Zifencei (FENCE.I), not implemented
#   ma_data: needs misaligned loads/stores, which this core reports as errors
RISCV_TESTS ?= third_party/riscv-tests
ISA_TESTS ?= $(filter-out fence_i ma_data, \
	$(basename $(notdir $(wildcard $(RISCV_TESTS)/isa/rv32ui/*.S))))

isa: $(call SIM_BIN,soc)
	@test -d $(RISCV_TESTS)/isa || { echo "missing $(RISCV_TESTS): run git submodule update --init"; exit 1; }
	@pass=0; failed=""; \
	for t in $(ISA_TESTS); do \
		if $(MAKE) --no-print-directory prog-rv32ui-$$t PLUSARGS=+max_cycles=20000 > build/isa-$$t.log 2>&1; then \
			pass=$$((pass+1)); echo "PASS  rv32ui-$$t"; \
		else \
			failed="$$failed $$t"; echo "FAIL  rv32ui-$$t   (log: build/isa-$$t.log)"; \
		fi; \
	done; \
	echo "rv32ui: $$pass/$(words $(ISA_TESTS)) passed"; \
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
	@yosys -q -l build/synth.log -p "read_verilog build/synth.v; synth -top $(strip $(SYNTH_TOP)); stat" >/dev/null
	@sed -n '/Printing statistics/,$$p' build/synth.log
	@if grep -i "latch inferred" build/synth.log | grep -vqi "no latch inferred"; then \
		echo "ERROR: latch inferred - see build/synth.log"; \
		grep -i "latch inferred" build/synth.log | grep -vi "no latch inferred"; exit 1; \
	fi
	@echo "Synthesis OK, no latches (full log: build/synth.log)"

clean:
	rm -rf build sw/build
