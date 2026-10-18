import cocotb

from ..helpers.raster import run_raster_case

WIDTH = 32
HEIGHT = 32
THREADS = 32


@cocotb.test()
async def test_raster32x32(dut):
    await run_raster_case(dut, "raster32x32", WIDTH, HEIGHT, THREADS)
