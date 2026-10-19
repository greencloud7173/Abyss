import cocotb

from ..helpers.program import run_case


def u32(value):
    return value & 0xFFFFFFFF


def i32(value):
    value &= 0xFFFFFFFF
    return value - 0x100000000 if value & 0x80000000 else value


def sext(value, bits):
    sign = 1 << (bits - 1)
    return (value & (sign - 1)) - (value & sign)


@cocotb.test()
async def test_mem(dut):
    # Low byte 0x80.., byte 1 0x7F.., upper half 0x8001..
    inputs = [(0x80017F80 + i * 0x10101) & 0xFFFFFFFF for i in range(4)]

    data_memory, _ = await run_case(
        dut,
        "mem",
        data=[],
        threads=4,
        display=36,
    )

    expected = [
        [u32(i32(sext(v & 0xFF, 8))) for v in inputs],           # LB
        [(v >> 8) & 0xFF for v in inputs],                       # LBU
        [u32(i32(sext((v >> 16) & 0xFFFF, 16))) for v in inputs],  # LH
        [(v >> 16) & 0xFFFF for v in inputs],                    # LHU
    ]

    # Outputs start at words 16, 20, 24, 28.
    for group, values in enumerate(expected):
        base = 16 + group * 4
        for i, value in enumerate(values):
            result = data_memory.memory[base + i]
            assert result == value, (
                f"group {group} index {i}: expected {value:#010x}, "
                f"got {result:#010x}"
            )
