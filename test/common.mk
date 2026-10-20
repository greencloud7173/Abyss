# Shared rules for one Abyss test case.
#
# Every test/<case>/Makefile only needs:
#   include ../common.mk
#
# Build:
#   clang --target=abyss -S <case>.c       (kernel assembly, kept in build/)
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
KERNEL_ASM := $(BUILD)/$(CASE).s
START_O := $(BUILD)/start.o
ELF := $(BUILD)/$(CASE).elf
BIN := $(BUILD)/$(CASE).bin
HEADERS := $(wildcard $(ROOT)/test/helpers/*.h) $(wildcard $(ROOT)/tools/*.h)
RTL_SIM := $(ROOT)/build/sim.vvp

COCOTB_VPI := $(shell cocotb-config --lib-entry VPI icarus)
export LIBPYTHON_LOC := $(shell cocotb-config --libpython)
export PYGPI_PYTHON_BIN := $(shell cocotb-config --python-bin)
export GPI_USERS := $(LIBPYTHON_LOC);$(shell cocotb-config --pygpi-entry-point)

# ---------------------------------------------------------------------------
# Simulator selection
#   SIM=verilator  默认：Verilator 5.x + cocotb VPI，同一拍快 5~20 倍
#   SIM=icarus     iverilog + vvp（找不到 Verilator 时自动回退）
#
#   make test raster128x128              # 默认走 Verilator
#   make test raster128x128 SIM=icarus   # 强制用 iverilog
# ---------------------------------------------------------------------------
VERILATOR ?= $(firstword $(wildcard $(HOME)/.local/verilator/usr/bin/verilator_bin) \
                          $(shell command -v verilator 2>/dev/null))
ifeq ($(VERILATOR),)
  SIM ?= icarus
else
  SIM ?= verilator
  # The RPM's perl wrapper is unusable here (missing perl-FindBin), so the local
  # install is driven through verilator_bin, which needs VERILATOR_ROOT.
  ifneq ($(findstring $(HOME)/.local/verilator,$(VERILATOR)),)
    VERILATOR_ROOT ?= $(HOME)/.local/verilator/usr/share/verilator
  endif
endif
VLT_ENV := $(if $(VERILATOR_ROOT),VERILATOR_ROOT=$(VERILATOR_ROOT),)

VLT_BUILD ?= $(ROOT)/build/vsim
COCOTB_SHARE := $(shell python3 -m cocotb_tools.config --share)
COCOTB_LIBDIR := $(shell python3 -m cocotb_tools.config --lib-dir)
VLT_CPP := $(COCOTB_SHARE)/lib/verilator/verilator.cpp
VLT_TOP := $(VLT_BUILD)/Vtop

.PHONY: all test compile clean

all: test

$(BUILD):
	mkdir -p $@

ABYSS_CFLAGS := --target=abyss -O2 -fno-pic -fno-delete-null-pointer-checks \
	-fno-vectorize -fno-slp-vectorize -nostdlib -I $(ROOT)/tools

$(KERNEL_ASM): $(KERNEL_C) $(HEADERS) | $(BUILD)
	$(ABYSS_CLANG) $(ABYSS_CFLAGS) -S $< -o $@

$(KERNEL_O): $(KERNEL_C) $(HEADERS) | $(BUILD)
	$(ABYSS_CLANG) $(ABYSS_CFLAGS) -c $< -o $@

$(START_O): $(START_S) | $(BUILD)
	$(LLVM_MC) -arch=abyss -filetype=obj $< -o $@

$(ELF): $(START_O) $(KERNEL_O)
	$(LD_LLD) --image-base=0 -Ttext=0 -e _start -o $@ $^

$(BIN): $(ELF)
	$(LLVM_OBJCOPY) -O binary --only-section=.text $< $@

compile: $(BIN) $(KERNEL_ASM)

ifeq ($(SIM),verilator)
# Verilator model of the whole GPU, shared by every test case (build/vsim).
# `--public-flat-rw` lets cocotb reach internal signals through VPI;
# `verilator.cpp` from cocotb drives cocotb's own scheduler.
$(ROOT)/build/gpu.v: $(wildcard $(ROOT)/src/*.v)
	$(MAKE) -C $(ROOT) compile

$(VLT_TOP): $(ROOT)/build/gpu.v $(VLT_CPP)
	$(VLT_ENV) $(VERILATOR) -cc --exe -Mdir $(VLT_BUILD) \
		--top-module gpu --vpi --public-flat-rw --prefix Vtop -o Vtop \
		-Wno-fatal -Wno-PINMISSING -Wno-lint \
		-LDFLAGS "-Wl,-rpath,$(COCOTB_LIBDIR) -L$(COCOTB_LIBDIR) -lcocotbvpi_verilator" \
		$(ROOT)/build/gpu.v $(VLT_CPP)
	$(MAKE) -C $(VLT_BUILD) -f Vtop.mk -j$(shell nproc)

test: $(BIN) $(KERNEL_ASM) $(VLT_TOP)
	cd $(ROOT) && env COCOTB_TEST_MODULES=test.$(CASE).test_$(CASE) \
		COCOTB_TOPLEVEL=gpu $(VLT_TOP)
else
test: $(BIN) $(KERNEL_ASM)
	$(MAKE) -C $(ROOT) sim
	cd $(ROOT) && env COCOTB_TEST_MODULES=test.$(CASE).test_$(CASE) \
		vvp -m $(COCOTB_VPI) $(RTL_SIM)
endif

clean:
	rm -rf $(BUILD)
