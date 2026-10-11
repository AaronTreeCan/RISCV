# rv32i-core - top-level build
#
#   make test            run every unit test listed in UNIT_TESTS
#   make test-alu        run one unit test (rtl/alu.sv + tb/test_alu.py)
#   make waves-alu       same, but also dump a waveform for GTKWave
#   make prog-hello      compile sw/c/hello.c, run it on the CPU (Week 6+)
#   make lint            Verilator lint on every rtl/*.sv file
#   make synth           Yosys synthesis of SYNTH_TOP; fails if a latch is inferred
#   make clean           delete build outputs
#
# Add a block: create rtl/<name>.sv and tb/test_<name>.py, then add <name> below.

UNIT_TESTS ?= blinky

# Your top-level module once the core exists (core + memory), used by prog-*
CPU_TOP ?= soc

# Module to synthesize. Change to your core's top module in Week 5.
SYNTH_TOP ?= blinky

SIM ?= icarus

export SIM

.PHONY: test lint synth clean

test: $(addprefix test-,$(UNIT_TESTS))
	@echo "All unit tests passed: $(UNIT_TESTS)"

test-%:
	@rm -f build/sim/$*/results.xml
	@$(MAKE) --no-print-directory -f tb/cocotb.mk TOP=$*
	@python3 scripts/check_results.py build/sim/$*/results.xml

waves-%:
	@rm -rf build/sim/$*
	@$(MAKE) --no-print-directory -f tb/cocotb.mk TOP=$* WAVES=1
	@python3 scripts/check_results.py build/sim/$*/results.xml
	@echo "Waveform written to build/sim/$*/ - open the .fst file with: gtkwave build/sim/$*/$*.fst"

prog-%:
	@$(MAKE) --no-print-directory -C sw build/$*.hex
	@rm -rf build/sim/prog-$*
	@$(MAKE) --no-print-directory -f tb/cocotb.mk TOP=$(strip $(CPU_TOP)) TESTMOD=test_program \
		SIMDIR=prog-$* PLUSARGS=+hex=$(CURDIR)/sw/build/$*.hex
	@python3 scripts/check_results.py build/sim/prog-$*/results.xml

lint:
	@for f in rtl/*.sv; do \
		echo "lint $$f"; \
		verilator --lint-only -Wall -Irtl $$f || exit 1; \
	done

synth:
	@mkdir -p build
	@yosys -q -l build/synth.log -p "read_verilog -sv rtl/*.sv; synth -top $(strip $(SYNTH_TOP)); stat" >/dev/null
	@sed -n '/Printing statistics/,$$p' build/synth.log
	@if grep -qi "latch inferred" build/synth.log; then \
		echo "ERROR: latch inferred - see build/synth.log"; \
		grep -i "latch inferred" build/synth.log; exit 1; \
	fi
	@echo "Synthesis OK, no latches (full log: build/synth.log)"

clean:
	rm -rf build sw/build results.xml
