import cocotb

from ..helpers.program import run_case


def u32(value):
    return value & 0xFFFFFFFF


def i32(value):
    value &= 0xFFFFFFFF
    return value - 0x100000000 if value & 0x80000000 else value


def sdiv(a, b):
    """C / RISC-V signed division: truncate toward zero, x/0 = -1."""
    if b == 0:
        return -1
    q = abs(a) // abs(b)
    return q if (a < 0) == (b < 0) else -q


def srem(a, b):
    """C / RISC-V signed remainder: sign follows the dividend, x%0 = x."""
    if b == 0:
        return a
    return i32(a - i32(sdiv(a, b)) * b)


def udiv(a, b):
    ua, ub = u32(a), u32(b)
    return u32(0xFFFFFFFF if ub == 0 else ua // ub)


def urem(a, b):
    ua, ub = u32(a), u32(b)
    return ua if ub == 0 else ua % ub


@cocotb.test()
async def test_div(dut):
    # 1/0, -7/2, 0x7FFFFFFF/3, INT_MIN/-1 -> 覆盖除零、截断方向、溢出回绕
    a = [1, -7, 0x7FFFFFFF, i32(0x80000000)]
    b = [0, 2, 3, -1]
    z = [0, 0, 0, 0]

    data = [u32(x) for x in a + b + z] + [0] * 32

    data_memory, _ = await run_case(
        dut,
        "div",
        data=data,
        threads=4,
        display=44,
    )

    expected = [
        [sdiv(x, y) for x, y in zip(a, b)],   # words 12..15
        [srem(x, y) for x, y in zip(a, b)],   # words 16..19
        [udiv(x, y) for x, y in zip(a, b)],   # words 20..23
        [urem(x, y) for x, y in zip(a, b)],   # words 24..27
        [sdiv(x, 0) for x in a],              # words 28..31
        [srem(x, 0) for x in a],              # words 32..35
        [udiv(x, 0) for x in a],              # words 36..39
        [urem(x, 0) for x in a],              # words 40..43
    ]

    for group, values in enumerate(expected):
        base = 12 + group * 4
        for i, value in enumerate(values):
            result = data_memory.memory[base + i]
            assert result == u32(value), (
                f"group {group} index {i}: expected {u32(value):#010x}, "
                f"got {result:#010x}"
            )
