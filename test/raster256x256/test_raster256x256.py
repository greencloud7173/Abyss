import cocotb

from ..helpers.raster import run_raster_case

WIDTH = 256
HEIGHT = 256
THREADS = 128


@cocotb.test()
async def test_raster256x256(dut):
    await run_raster_case(dut, "raster256x256", WIDTH, HEIGHT, THREADS)
