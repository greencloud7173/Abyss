import cocotb

from ..helpers.program import run_case


@cocotb.test()
async def test_matmul(dut):
    data_memory, _ = await run_case(
        dut,
        "matmul",
        data=[],
        threads=4,
        display=12,
        thread_id=1,
    )

    # The matrices are filled by the kernel itself; C starts at word 8.
    matrix_a = [[1, 2], [3, 4]]
    matrix_b = [[1, 2], [3, 4]]
    expected_results = [
        matrix_a[0][0] * matrix_b[0][0] + matrix_a[0][1] * matrix_b[1][0],  # C[0,0]
        matrix_a[0][0] * matrix_b[0][1] + matrix_a[0][1] * matrix_b[1][1],  # C[0,1]
        matrix_a[1][0] * matrix_b[0][0] + matrix_a[1][1] * matrix_b[1][0],  # C[1,0]
        matrix_a[1][0] * matrix_b[0][1] + matrix_a[1][1] * matrix_b[1][1],  # C[1,1]
    ]
    for i, expected in enumerate(expected_results):
        result = data_memory.memory[i + 8]
        assert result == expected, f"Result mismatch at index {i}: expected {expected}, got {result}"
