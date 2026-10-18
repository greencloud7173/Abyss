import cocotb

from ..helpers.raster import run_raster_case

WIDTH = 16
HEIGHT = 16
THREADS = 16


@cocotb.test()
async def test_raster16x16(dut):
    await run_raster_case(dut, "raster16x16", WIDTH, HEIGHT, THREADS)
