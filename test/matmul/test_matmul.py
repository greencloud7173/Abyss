import cocotb

from ..helpers.program import run_case


@cocotb.test()
async def test_matmul(dut):
    data = [
        1, 2, 3, 4,  # A (2 x 2)
        1, 2, 3, 4,  # B (2 x 2)
    ]

    data_memory, _ = await run_case(
        dut,
        "matmul",
        data=data,
        threads=4,
        display=12,
        thread_id=1,
    )

    # The matrices are 2x2; C is stored starting at word 8.
    matrix_a = [data[0:2], data[2:4]]  # First matrix (2x2)
    matrix_b = [data[4:6], data[6:8]]  # Second matrix (2x2)
    expected_results = [
        matrix_a[0][0] * matrix_b[0][0] + matrix_a[0][1] * matrix_b[1][0],  # C[0,0]
        matrix_a[0][0] * matrix_b[0][1] + matrix_a[0][1] * matrix_b[1][1],  # C[0,1]
        matrix_a[1][0] * matrix_b[0][0] + matrix_a[1][1] * matrix_b[1][0],  # C[1,0]
        matrix_a[1][0] * matrix_b[0][1] + matrix_a[1][1] * matrix_b[1][1],  # C[1,1]
    ]
    for i, expected in enumerate(expected_results):
        result = data_memory.memory[i + 8]
        assert result == expected, f"Result mismatch at index {i}: expected {expected}, got {result}"
