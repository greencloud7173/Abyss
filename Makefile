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
# The sources are plain Verilog-2005 now (converted from SystemVerilog with sv2v
# once, comments and ANSI port lists restored by hand), so building is just
# concatenating them into one file for the simulators.
sim: compile
	iverilog -o build/sim.vvp -s gpu -g2012 build/gpu.v

compile:
	mkdir -p build
	cat src/*.v > build/gpu.v
# TODO: Get gtkwave visualizaiton

show_%: %.vcd %.gtkw
	gtkwave $^
