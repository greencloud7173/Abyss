import cocotb

from ..helpers.raster import run_raster_case

WIDTH = 1024
HEIGHT = 1024
THREADS = 128


@cocotb.test()
async def test_raster1024x1024(dut):
    await run_raster_case(dut, "raster1024x1024", WIDTH, HEIGHT, THREADS)
