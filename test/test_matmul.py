import cocotb
from cocotb.triggers import RisingEdge
from .helpers.setup import setup
from .helpers.memory import Memory
from .helpers.format import format_cycle
from .helpers.logger import logger

@cocotb.test()
async def test_matadd(dut):
    # Program Memory
    program_memory = Memory(dut=dut, addr_bits=32, data_bits=32, channels=1, name="program")
    # 注意:x0 (R0) 恒为 0,不能当普通寄存器用(这里用 R13 存全局线程号 i)
    # 访存用 RISC-V 偏移寻址:A/B/C 基址分别是 0 / 4 / 8,直接写进 LDR/STR 的立即数
    program = [
        0b00000011111011101000011010110011, # MUL  R13, %blockIdx, %blockDim
        0b00000001111101101000011010110011, # ADD  R13, R13, %threadIdx  ; i = blockIdx * blockDim + threadIdx
        0b00000000000100000000000010010011, # ADDI R1, x0, #1            ; increment
        0b00000000001000000000000100010011, # ADDI R2, x0, #2            ; N (matrix inner dimension)
        0b00000010001001101100001100110011, # DIV  R6, R13, R2           ; row = i // N
        0b00000010001000110000001110110011, # MUL  R7, R6, R2
        0b01000000011101101000001110110011, # SUB  R7, R13, R7           ; col = i % N
        0b00000000000000000000010000010011, # ADDI R8, x0, #0            ; acc = 0
        0b00000000000000000000010010010011, # ADDI R9, x0, #0            ; k = 0
                                            # LOOP:
        0b00000010001000110000010100110011, #   MUL  R10, R6, R2
        0b00000000100101010000010100110011, #   ADD  R10, R10, R9
        0b00000000000001010010010100000011, #   LDR  R10, 0(R10)         ; A[row * N + k]  (baseA = 0)
        0b00000010001001001000010110110011, #   MUL  R11, R9, R2
        0b00000000011101011000010110110011, #   ADD  R11, R11, R7
        0b00000000010001011010010110000011, #   LDR  R11, 4(R11)         ; B[k * N + col]  (baseB = 4)
        0b00000010101101010000011000110011, #   MUL  R12, R10, R11
        0b00000000110001000000010000110011, #   ADD  R8, R8, R12         ; acc += A[i] * B[i]
        0b00000000000101001000010010110011, #   ADD  R9, R9, R1          ; increment k
        0b11111100001001001100111011100011, #   BLT  R9, R2, LOOP        ; loop while k < N (offset -36B = -9 条)
        0b00000000100001101010010000100011, # STR  R8, 8(R13)            ; store C[i]  (baseC = 8)
        0b00000000000000000000000001011011  # RET
    ]

    # Data Memory
    data_memory = Memory(dut=dut, addr_bits=32, data_bits=32, channels=4, name="data")
    data = [
        1, 2, 3, 4, # Matrix A (2 x 2)
        1, 2, 3, 4, # Matrix B (2 x 2)
    ]

    # Device Control
    threads = 4

    await setup(
        dut=dut,
        program_memory=program_memory,
        program=program,
        data_memory=data_memory,
        data=data,
        threads=threads
    )

    data_memory.display(12)

    cycles = 0
    while dut.done.value != 1:
        data_memory.run()
        program_memory.run()

        await cocotb.triggers.ReadOnly()
        format_cycle(dut, cycles, thread_id=1)
        
        await RisingEdge(dut.clk)
        cycles += 1

    logger.info(f"Completed in {cycles} cycles")
    data_memory.display(12)


    # Assuming the matrices are 2x2 and the result is stored starting at address 9
    matrix_a = [data[0:2], data[2:4]]  # First matrix (2x2)
    matrix_b = [data[4:6], data[6:8]]  # Second matrix (2x2)
    expected_results = [
        matrix_a[0][0] * matrix_b[0][0] + matrix_a[0][1] * matrix_b[1][0],  # C[0,0]
        matrix_a[0][0] * matrix_b[0][1] + matrix_a[0][1] * matrix_b[1][1],  # C[0,1]
        matrix_a[1][0] * matrix_b[0][0] + matrix_a[1][1] * matrix_b[1][0],  # C[1,0]
        matrix_a[1][0] * matrix_b[0][1] + matrix_a[1][1] * matrix_b[1][1],  # C[1,1]
    ]
    for i, expected in enumerate(expected_results):
        result = data_memory.memory[i + 8]  # Results start at address 9
        assert result == expected, f"Result mismatch at index {i}: expected {expected}, got {result}"
