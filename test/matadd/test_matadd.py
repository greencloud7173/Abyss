import cocotb

from ..helpers.program import run_case


@cocotb.test()
async def test_matadd(dut):
    data_memory, _ = await run_case(
        dut,
        "matadd",
        data=[],
        threads=8,
        display=24,
    )

    expected_results = [i + i for i in range(8)]
    for i, expected in enumerate(expected_results):
        result = data_memory.memory[i + 16]
        assert result == expected, f"Result mismatch at index {i}: expected {expected}, got {result}"