import cocotb

from ..helpers.program import run_case


def u32(value):
    return value & 0xFFFFFFFF


def i32(value):
    value &= 0xFFFFFFFF
    return value - 0x100000000 if value & 0x80000000 else value


@cocotb.test()
async def test_slt(dut):
    # 0 / -1 / INT_MAX / INT_MIN 覆盖"符号相同"、"符号相反"、"相等"三种情形
    a = [0, -1, 0x7FFFFFFF, i32(0x80000000)]
    b = [0, 1, 0x7FFFFFFF, -1]

    data_memory, _ = await run_case(
        dut,
        "slt",
        data=[],
        threads=4,
        display=0,
    )

    expected = [
        [int(x < y) for x, y in zip(a, b)],                      # words  8..11  SLT
        [int(u32(x) < u32(y)) for x, y in zip(a, b)],            # words 12..15  SLTU
        [int(x < 5) for x in a],                                 # words 16..19  SLTI
        [int(u32(x) < 5) for x in a],                            # words 20..23  SLTIU
        [int(x < -1) for x in a],                                # words 24..27  SLTI  #-1
        [int(u32(x) < 0xFFFFFFFF) for x in a],                   # words 28..31  SLTIU #-1
    ]

    for group, values in enumerate(expected):
        base = 8 + group * 4
        for i, value in enumerate(values):
            result = data_memory.memory[base + i]
            assert result == u32(value), (
                f"group {group} index {i}: expected {u32(value):#010x}, "
                f"got {result:#010x}"
            )
