# cocotb build rules. The top-level Makefile calls this; you don't run it directly.
#
#   TOP      HDL module to simulate (rtl/<TOP>.sv)
#   TESTMOD  Python test module in tb/ (default: test_<TOP>)
#   SIMDIR   build folder name under build/sim/ (default: <TOP>)

TOP     ?= blinky
TESTMOD ?= test_$(TOP)
SIMDIR  ?= $(TOP)
SIM     ?= icarus

TOPLEVEL_LANG   := verilog
VERILOG_SOURCES := $(wildcard $(CURDIR)/rtl/*.sv)

# cocotb 1.x names and cocotb 2.x names, so either version works
TOPLEVEL            := $(TOP)
MODULE              := $(TESTMOD)
COCOTB_TOPLEVEL     := $(TOP)
COCOTB_TEST_MODULES := $(TESTMOD)

SIM_BUILD := $(CURDIR)/build/sim/$(SIMDIR)
export COCOTB_RESULTS_FILE := $(SIM_BUILD)/results.xml
export PYTHONPATH := $(CURDIR)/tb:$(PYTHONPATH)

ifeq ($(SIM),icarus)
COMPILE_ARGS += -g2012
endif

COCOTB_MAKEFILES := $(shell cocotb-config --makefiles 2>/dev/null)
ifeq ($(COCOTB_MAKEFILES),)
$(error cocotb not found. Activate your virtual environment (source .venv/bin/activate) and run: pip install -r requirements.txt)
endif

include $(COCOTB_MAKEFILES)/Makefile.sim
