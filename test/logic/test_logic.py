import cocotb

from ..helpers.program import run_case


def u32(value):
    return value & 0xFFFFFFFF


def i32(value):
    value &= 0xFFFFFFFF
    return value - 0x100000000 if value & 0x80000000 else value


@cocotb.test()
async def test_logic(dut):
    # 全 0 / 全 1 / 交替位 / 只有符号位,能同时覆盖"位全同""位全反"两种情况
    a = [0x12345678, -1, 0, i32(0x80000000)]
    b = [i32(0xF0F0F0F0), 0x00FF00FF, -1, 0x7FFFFFFF]

    data = [u32(x) for x in a + b] + [0] * 32

    data_memory, _ = await run_case(
        dut,
        "logic",
        data=data,
        threads=4,
        display=0,
    )

    expected = [
        [u32(x) & u32(y) for x, y in zip(a, b)],                 # words  8..11  AND
        [u32(x) | u32(y) for x, y in zip(a, b)],                 # words 12..15  OR
        [u32(x) ^ u32(y) for x, y in zip(a, b)],                 # words 16..19  XOR
        [u32(x) & 0xFF for x in a],                              # words 20..23  ANDI #255
        [u32(x) | 0x0F for x in a],                              # words 24..27  ORI  #15
        [u32(~u32(x)) for x in a],                               # words 28..31  XORI #-1
        [u32(x) & 0xFFFFFFF0 for x in a],                        # words 32..35  ANDI #-16
        [(u32(x) >> 8) & 0xFF for x in a],                       # words 36..39  SRLI + ANDI
    ]

    for group, values in enumerate(expected):
        base = 8 + group * 4
        for i, value in enumerate(values):
            result = data_memory.memory[base + i]
            assert result == u32(value), (
                f"group {group} index {i}: expected {u32(value):#010x}, "
                f"got {result:#010x}"
            )
