import cocotb

from ..helpers.raster import run_raster_case

WIDTH = 64
HEIGHT = 64
THREADS = 64


@cocotb.test()
async def test_raster64x64(dut):
    await run_raster_case(dut, "raster64x64", WIDTH, HEIGHT, THREADS)
