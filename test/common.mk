# Shared rules for one Abyss test case.
#
# Every test/<case>/Makefile only needs:
#   include ../common.mk
#
# Build:
#   clang --target=abyss -c <case>.c       (kernel object)
#   llvm-mc -arch=abyss <start.s>          (startup object)
#   ld.lld --image-base=0 -Ttext=0         (ELF link)
#   llvm-objcopy -O binary --only-section=.text

ROOT ?= $(abspath ../..)
CASE ?= $(notdir $(CURDIR))

ABYSS_CLANG ?= /home/greencloud7173/llvm-project/build-abyss-clang/bin/clang
LLVM_MC ?= /home/greencloud7173/llvm-project/build/bin/llvm-mc
LLVM_OBJCOPY ?= /home/greencloud7173/llvm-project/build/bin/llvm-objcopy
LD_LLD ?= ld.lld

BUILD ?= $(CURDIR)/build
SRC ?= $(CURDIR)/src
KERNEL_C := $(SRC)/$(CASE).c
START_S := $(SRC)/start.s
KERNEL_O := $(BUILD)/$(CASE).o
START_O := $(BUILD)/start.o
ELF := $(BUILD)/$(CASE).elf
BIN := $(BUILD)/$(CASE).bin
RTL_SIM := $(ROOT)/build/sim.vvp

COCOTB_VPI := $(shell cocotb-config --lib-entry VPI icarus)
export LIBPYTHON_LOC := $(shell cocotb-config --libpython)
export PYGPI_PYTHON_BIN := $(shell cocotb-config --python-bin)
export GPI_USERS := $(LIBPYTHON_LOC);$(shell cocotb-config --pygpi-entry-point)

.PHONY: all test clean

all: test

$(BUILD):
	mkdir -p $@

$(KERNEL_O): $(KERNEL_C) | $(BUILD)
	$(ABYSS_CLANG) --target=abyss -O2 -fno-pic -fno-delete-null-pointer-checks \
		-nostdlib -I $(ROOT)/tools/abysscc -c $< -o $@

$(START_O): $(START_S) | $(BUILD)
	$(LLVM_MC) -arch=abyss -filetype=obj $< -o $@

$(ELF): $(START_O) $(KERNEL_O)
	$(LD_LLD) --image-base=0 -Ttext=0 -e _start -o $@ $^

$(BIN): $(ELF)
	$(LLVM_OBJCOPY) -O binary --only-section=.text $< $@

test: $(BIN)
	$(MAKE) -C $(ROOT) sim
	cd $(ROOT) && env COCOTB_TEST_MODULES=test.$(CASE).test_$(CASE) \
		vvp -m $(COCOTB_VPI) $(RTL_SIM)

clean:
	rm -rf $(BUILD)
