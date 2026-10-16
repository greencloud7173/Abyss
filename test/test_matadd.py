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
    # 访存用 RISC-V 偏移寻址:mem[rs1 + imm],所以 A/B/C 的基址直接写进立即数
    program = [
        0b00000011111011101000011010110011, # MUL  R13, %blockIdx, %blockDim
        0b00000001111101101000011010110011, # ADD  R13, R13, %threadIdx  ; i = blockIdx * blockDim + threadIdx
        0b00000001000000000000000010010011, # ADDI R1, x0, #16           ; baseC = 16
        0b00000000110100001000000010110011, # ADD  R1, R1, R13           ; addr(C[i]) = baseC + i
        0b00000000000001101010001000000011, # LDR  R4, 0(R13)            ; A[i]  (baseA = 0)
        0b00000000100001101010001010000011, # LDR  R5, 8(R13)            ; B[i]  (baseB = 8)
        0b00000000010100100000001100110011, # ADD  R6, R4, R5            ; C[i] = A[i] + B[i]
        0b00000000011000001010000000100011, # STR  R6, 0(R1)             ; store C[i] in global memory
        0b00000000000000000000000001011011, # RET
    ]

    # Data Memory
    data_memory = Memory(dut=dut, addr_bits=32, data_bits=32, channels=4, name="data")
    data = [
        0, 1, 2, 3, 4, 5, 6, 7, # Matrix A (1 x 8)
        0, 1, 2, 3, 4, 5, 6, 7  # Matrix B (1 x 8)
    ]

    # Device Control
    threads = 8

    await setup(
        dut=dut,
        program_memory=program_memory,
        program=program,
        data_memory=data_memory,
        data=data,
        threads=threads
    )

    data_memory.display(24)

    cycles = 0
    while dut.done.value != 1:
        data_memory.run()
        program_memory.run()

        await cocotb.triggers.ReadOnly()
        format_cycle(dut, cycles)
        
        await RisingEdge(dut.clk)
        cycles += 1

    logger.info(f"Completed in {cycles} cycles")
    data_memory.display(24)

    expected_results = [a + b for a, b in zip(data[0:8], data[8:16])]
    for i, expected in enumerate(expected_results):
        result = data_memory.memory[i + 16]
        assert result == expected, f"Result mismatch at index {i}: expected {expected}, got {result}"