import cocotb

from ..helpers.raster import run_raster_case

WIDTH = 128
HEIGHT = 128
THREADS = 128


@cocotb.test()
async def test_raster128x128(dut):
    await run_raster_case(dut, "raster128x128", WIDTH, HEIGHT, THREADS)
