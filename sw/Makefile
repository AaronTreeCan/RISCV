# Builds programs for the core. Usually called from the top-level Makefile
# (make prog-<name>), but you can run it directly:
#
#   make -C sw build/hello.hex     C program in c/hello.c (linked with crt0)
#   make -C sw build/add.hex       assembly test in asm/add.S (provides its own _start)
#   make -C sw build/rv32ui-add.hex  official ISA test (third_party/riscv-tests)
#   make -C sw build/hello.dis     disassembly, very useful when debugging
#
# Output: build/<name>.hex, one 32-bit word per line, for $readmemh.

CROSS   ?= riscv64-unknown-elf-
CC      := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump

ARCH    := -march=rv32i -mabi=ilp32
LDFLAGS := -nostdlib -mno-relax -T common/link.ld -Wl,--no-warn-rwx-segments
CFLAGS  := $(ARCH) -O2 -ffreestanding -fno-builtin -Wall -Icommon

BUILD := build

.PRECIOUS: $(BUILD)/%.elf $(BUILD)/%.bin

# C programs: crt0 + your code + libgcc (software multiply/divide, since there's no M extension)
$(BUILD)/%.elf: c/%.c common/crt0.S common/link.ld common/mmio.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(LDFLAGS) common/crt0.S $< -lgcc -o $@

# Assembly tests: no crt0, the file defines _start itself
$(BUILD)/%.elf: asm/%.S common/link.ld
	@mkdir -p $(BUILD)
	$(CC) $(ARCH) $(LDFLAGS) $< -o $@

# riscv-tests: the test source + our minimal environment (isa/riscv_test.h)
RISCV_TESTS ?= ../third_party/riscv-tests
$(BUILD)/rv32ui-%.elf: $(RISCV_TESTS)/isa/rv32ui/%.S isa/riscv_test.h common/link.ld
	@mkdir -p $(BUILD)
	$(CC) $(ARCH) $(LDFLAGS) -Iisa -I$(RISCV_TESTS)/isa/macros/scalar $< -o $@

$(BUILD)/%.bin: $(BUILD)/%.elf
	$(OBJCOPY) -O binary $< $@

$(BUILD)/%.hex: $(BUILD)/%.bin
	python3 ../scripts/bin2hex.py $< $@

$(BUILD)/%.dis: $(BUILD)/%.elf
	$(OBJDUMP) -d -M no-aliases $< > $@

clean:
	rm -rf $(BUILD)
