TEST_CASES = $(patsubst test/%/src,%,$(wildcard test/*/src))

.PHONY: test sim compile $(TEST_CASES) test_%

export LIBPYTHON_LOC := $(shell cocotb-config --libpython)
export PYGPI_PYTHON_BIN := $(shell cocotb-config --python-bin)
export GPI_USERS := $(LIBPYTHON_LOC);$(shell cocotb-config --pygpi-entry-point)

# `make test matadd`, `make test CASE=matadd` and `make test_matadd` all work.
test:
	@if [ -n "$(CASE)" ]; then \
		$(MAKE) -C test/$(CASE) test; \
	elif [ -z "$(filter-out test,$(MAKECMDGOALS))" ]; then \
		echo "usage: make test <case>   (cases: $(TEST_CASES))"; \
	fi

$(TEST_CASES):
	$(MAKE) -C test/$@ test

test_%:
	$(MAKE) -C test/$* test

# Shared RTL build.  Test subdirectory Makefiles call `make -C ../.. sim`.
sim: compile
	iverilog -o build/sim.vvp -s gpu -g2012 build/gpu.v

compile:
	$(MAKE) compile_alu
	sv2v -I src/* -w build/gpu.v
	echo "" >> build/gpu.v
	cat build/alu.v >> build/gpu.v
	echo '`timescale 1ns/1ns' > build/temp.v
	cat build/gpu.v >> build/temp.v
	mv build/temp.v build/gpu.v

compile_%:
	sv2v -w build/$*.v src/$*.sv

# TODO: Get gtkwave visualizaiton

show_%: %.vcd %.gtkw
	gtkwave $^
