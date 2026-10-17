import cocotb

from ..helpers.program import run_case


@cocotb.test()
async def test_matadd(dut):
    data = [
        0, 1, 2, 3, 4, 5, 6, 7,  # A
        0, 1, 2, 3, 4, 5, 6, 7,  # B
    ]

    data_memory, _ = await run_case(
        dut,
        "matadd",
        data=data,
        threads=8,
        display=24,
    )

    expected_results = [a + b for a, b in zip(data[0:8], data[8:16])]
    for i, expected in enumerate(expected_results):
        result = data_memory.memory[i + 16]
        assert result == expected, f"Result mismatch at index {i}: expected {expected}, got {result}"