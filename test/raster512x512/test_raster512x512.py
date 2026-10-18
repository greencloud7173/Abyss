import cocotb

from ..helpers.raster import run_raster_case

WIDTH = 512
HEIGHT = 512
THREADS = 128


@cocotb.test()
async def test_raster512x512(dut):
    await run_raster_case(dut, "raster512x512", WIDTH, HEIGHT, THREADS)
