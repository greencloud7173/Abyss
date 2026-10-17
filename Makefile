ABYSSCC ?= tools/abysscc/abysscc
TEST_CASES = $(patsubst test/%/src,%,$(wildcard test/*/src))

.PHONY: test compile $(TEST_CASES)

export LIBPYTHON_LOC=$(shell cocotb-config --libpython)
export PYGPI_PYTHON_BIN=$(shell cocotb-config --python-bin)
export GPI_USERS=$(LIBPYTHON_LOC);$(shell cocotb-config --pygpi-entry-point)

# `make test matadd`, `make test CASE=matadd` and `make test_matadd` all work.
test:
	@if [ -n "$(CASE)" ]; then \
		$(MAKE) test_$(CASE); \
	elif [ -z "$(filter-out test,$(MAKECMDGOALS))" ]; then \
		echo "usage: make test <case>   (cases: $(TEST_CASES))"; \
	fi

$(TEST_CASES):
	$(MAKE) test_$@

# C build products go to test/<case>/build/; RTL products stay in root build/.
test_%:
	@test -f test/$*/src/$*.c || { echo "missing test/$*/src/$*.c"; exit 1; }
	@test -f test/$*/src/start.s || { echo "missing test/$*/src/start.s"; exit 1; }
	@mkdir -p test/$*/build
	$(ABYSSCC) --start test/$*/src/start.s --raw test/$*/src/$*.c -o test/$*/build/$*.o
	$(MAKE) compile
	iverilog -o build/sim.vvp -s gpu -g2012 build/gpu.v
	COCOTB_TEST_MODULES=test.$*.test_$* vvp -m $(shell cocotb-config --lib-entry VPI icarus) build/sim.vvp

compile:
	make compile_alu
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
