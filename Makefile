# rv32i-core - top-level build
#
#   make test            run every unit test listed in UNIT_TESTS
#   make test-alu        run one unit test (rtl/alu.sv + tb/tb_alu.sv), Icarus by default
#   make test-alu SIM=verilator   same test on Verilator 5
#   make waves-alu       same, but also dump a .vcd waveform for GTKWave
#   make prog-hello      compile sw/c/hello.c, run it on the CPU (Week 6+)
#   make lint            Verilator lint on every rtl/*.sv file
#   make synth           Yosys synthesis of SYNTH_TOP; fails if a latch is inferred
#   make clean           delete build outputs
#
# Add a block: create rtl/<name>.sv and tb/tb_<name>.sv, then add <name> below.
# A testbench passes by printing "TEST PASSED"; on failure it calls $fatal.

UNIT_TESTS ?= alu

# Your top-level module once the core exists (core + memory), used by prog-*
CPU_TOP ?= soc

# Module to synthesize. Change to your core's top module in Week 5.
SYNTH_TOP ?= alu

SIM ?= icarus

export SIM

.PHONY: test lint synth clean

test: $(addprefix test-,$(UNIT_TESTS))
	@echo "All unit tests passed: $(UNIT_TESTS)"

# Unit tests: self-checking SystemVerilog testbenches (tb/tb_<name>.sv)
test-%:
	@mkdir -p build/sim/$*
ifeq ($(SIM),verilator)
	@verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style --top-module tb_$* \
		-Mdir build/sim/$*/obj -o tb_$* $(SRCS) tb/tb_$*.sv > build/sim/$*/build.log
	@build/sim/$*/obj/tb_$* $(PLUSARGS) | tee build/sim/$*/sim.log
else
	@iverilog -g2012 -Wno-sensitivity-entire-array -o build/sim/$*/tb_$*.vvp $(SRCS) tb/tb_$*.sv
	@vvp -n build/sim/$*/tb_$*.vvp $(PLUSARGS) | tee build/sim/$*/sim.log
endif
	@grep -q "TEST PASSED" build/sim/$*/sim.log

waves-%:
	@$(MAKE) --no-print-directory test-$* SIM=icarus PLUSARGS=+waves
	@echo "Waveform: gtkwave build/sim/$*/tb_$*.vcd"

prog-%:
	@$(MAKE) --no-print-directory -C sw build/$*.hex
	@rm -rf build/sim/prog-$*
	@$(MAKE) --no-print-directory -f tb/cocotb.mk TOP=$(strip $(CPU_TOP)) TESTMOD=test_program \
		SIMDIR=prog-$* PLUSARGS=+hex=$(CURDIR)/sw/build/$*.hex
	@python3 scripts/check_results.py build/sim/prog-$*/results.xml

PKGS := $(wildcard rtl/*_pkg.sv)
SRCS := $(PKGS) $(filter-out $(PKGS),$(wildcard rtl/*.sv))

lint:
	@for f in $(filter-out $(PKGS),$(wildcard rtl/*.sv)); do \
		echo "lint $$f"; \
		verilator --lint-only -Wall -Irtl $(PKGS) $$f || exit 1; \
	done

# Yosys's built-in parser can't read SV packages/imports, so sv2v converts
# rtl/*.sv to plain Verilog first.
synth:
	@mkdir -p build
	@sv2v $(SRCS) > build/synth.v
	@yosys -q -l build/synth.log -p "read_verilog build/synth.v; synth -top $(strip $(SYNTH_TOP)); stat" >/dev/null
	@sed -n '/Printing statistics/,$$p' build/synth.log
	@if grep -i "latch inferred" build/synth.log | grep -vqi "no latch inferred"; then \
		echo "ERROR: latch inferred - see build/synth.log"; \
		grep -i "latch inferred" build/synth.log | grep -vi "no latch inferred"; exit 1; \
	fi
	@echo "Synthesis OK, no latches (full log: build/synth.log)"

clean:
	rm -rf build sw/build results.xml
