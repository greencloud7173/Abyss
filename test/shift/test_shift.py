import cocotb

from ..helpers.program import run_case


def u32(value):
    return value & 0xFFFFFFFF


def i32(value):
    value &= 0xFFFFFFFF
    return value - 0x100000000 if value & 0x80000000 else value


def sll(value, amount):
    return u32(value << (amount & 31))


def srl(value, amount):
    return u32(value) >> (amount & 31)


def sra(value, amount):
    return u32(i32(value) >> (amount & 31))


@cocotb.test()
async def test_shift(dut):
    data = [
        1, 0xFFFFFFF8, 0x7FFFFFFF, 0x80000000,  # a
        1, 2, 3, 4,                              # sh
    ]

    data_memory, _ = await run_case(
        dut,
        "shift",
        data=data,
        threads=4,
        display=40,
    )

    a = data[0:4]
    sh = data[4:8]

    expected = [
        [sll(value, 2) for value in a],
        [sra(value, 1) for value in a],
        [srl(value, 1) for value in a],
        [sll(value, n) for value, n in zip(a, sh)],
        [sra(value, n) for value, n in zip(a, sh)],
        [srl(value, n) for value, n in zip(a, sh)],
    ]

    for group, values in enumerate(expected):
        base = 8 + group * 4
        for i, value in enumerate(values):
            result = data_memory.memory[base + i]
            assert result == value, (
                f"group {group} index {i}: expected {value:#010x}, "
                f"got {result:#010x}"
            )
