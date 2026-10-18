#!/usr/bin/env python3
"""Small functional simulator for the Abyss ISA.

Used to sanity-check programs produced by abysscc without running Verilator.
It implements the Abyss instructions used by the tests, including the
SLL/SRL/SRA and SLLI/SRLI/SRAI shifts.  Data memory is byte-addressed:
the simulator maps byte_address >> 2 to a word and uses byte lanes for
LB/LH/LBU/LHU/SB/SH.
"""

import argparse
import os
import struct
import subprocess
import tempfile

OBJCOPY = "/home/greencloud7173/llvm-project/build/bin/llvm-objcopy"


def sext(value, bits):
    sign = 1 << (bits - 1)
    return (value & (sign - 1)) - (value & sign)


def i32(value):
    value &= 0xFFFFFFFF
    return value - 0x100000000 if value & 0x80000000 else value


def u32(value):
    return value & 0xFFFFFFFF


def sdiv(a, b):
    if b == 0:
        raise ZeroDivisionError("DIV by zero")
    q = abs(a) // abs(b)
    return -q if (a < 0) != (b < 0) else q


class Cpu:
    def __init__(self, program, memory, block_idx, block_dim, thread_idx):
        self.p = program
        self.mem = memory
        self.r = [0] * 32
        self.r[29] = block_idx
        self.r[30] = block_dim
        self.r[31] = thread_idx
        self.pc = 0

    def wr(self, rd, value):
        if rd != 0 and rd < 29:
            self.r[rd] = i32(value)

    def run(self, max_steps=100000):
        for _ in range(max_steps):
            if self.pc < 0 or self.pc >= len(self.p):
                raise RuntimeError(f"PC out of range: {self.pc}")
            w = self.p[self.pc]
            opcode = w & 0x7F
            rd = (w >> 7) & 0x1F
            funct3 = (w >> 12) & 0x7
            rs1 = (w >> 15) & 0x1F
            rs2 = (w >> 20) & 0x1F
            funct7 = (w >> 25) & 0x7F
            imm_i = sext((w >> 20) & 0xFFF, 12)

            if opcode == 0x33:
                if funct3 == 0 and funct7 == 0:
                    self.wr(rd, self.r[rs1] + self.r[rs2])
                elif funct3 == 0 and funct7 == 0x20:
                    self.wr(rd, self.r[rs1] - self.r[rs2])
                elif funct3 == 0 and funct7 == 1:
                    self.wr(rd, self.r[rs1] * self.r[rs2])
                elif funct3 == 4 and funct7 == 1:
                    self.wr(rd, sdiv(self.r[rs1], self.r[rs2]))
                elif funct3 == 1 and funct7 == 0:
                    self.wr(rd, self.r[rs1] << (self.r[rs2] & 31))
                elif funct3 == 5 and funct7 == 0:
                    self.wr(rd, (self.r[rs1] & 0xFFFFFFFF) >> (self.r[rs2] & 31))
                elif funct3 == 5 and funct7 == 0x20:
                    self.wr(rd, i32(self.r[rs1]) >> (self.r[rs2] & 31))
                else:
                    raise RuntimeError(f"unsupported R-type {w:08x}")
                self.pc += 1
            elif opcode == 0x13:
                shamt = (w >> 20) & 0x1F
                if funct3 == 0:
                    self.wr(rd, self.r[rs1] + imm_i)
                elif funct3 == 1 and funct7 == 0:
                    self.wr(rd, self.r[rs1] << shamt)
                elif funct3 == 5 and funct7 == 0:
                    self.wr(rd, (self.r[rs1] & 0xFFFFFFFF) >> shamt)
                elif funct3 == 5 and funct7 == 0x20:
                    self.wr(rd, i32(self.r[rs1]) >> shamt)
                else:
                    raise RuntimeError(f"unsupported I-type {w:08x}")
                self.pc += 1
            elif opcode == 0x03:
                byte_addr = (self.r[rs1] + imm_i) & 0xFFFFFFFF
                word = self.mem.get(byte_addr >> 2, 0) & 0xFFFFFFFF
                lane = byte_addr & 3
                if funct3 == 0:  # LB
                    value = sext((word >> (lane * 8)) & 0xFF, 8)
                elif funct3 == 1:  # LH
                    value = sext((word >> ((lane >> 1) * 16)) & 0xFFFF, 16)
                elif funct3 == 2:  # LDR
                    value = word
                elif funct3 == 4:  # LBU
                    value = (word >> (lane * 8)) & 0xFF
                elif funct3 == 5:  # LHU
                    value = (word >> ((lane >> 1) * 16)) & 0xFFFF
                else:
                    raise RuntimeError(f"unsupported load {w:08x}")
                self.wr(rd, value)
                self.pc += 1
            elif opcode == 0x23:
                imm = (((w >> 25) & 0x7F) << 5) | ((w >> 7) & 0x1F)
                imm = sext(imm, 12)
                byte_addr = (self.r[rs1] + imm) & 0xFFFFFFFF
                word_addr = byte_addr >> 2
                lane = byte_addr & 3
                old = self.mem.get(word_addr, 0) & 0xFFFFFFFF
                data = self.r[rs2] & 0xFFFFFFFF
                if funct3 == 0:  # SB
                    shift = lane * 8
                    mask = 0xFF << shift
                    value = (old & ~mask) | ((data & 0xFF) << shift)
                elif funct3 == 1:  # SH
                    shift = (lane >> 1) * 16
                    mask = 0xFFFF << shift
                    value = (old & ~mask) | ((data & 0xFFFF) << shift)
                elif funct3 == 2:  # STR
                    value = data
                else:
                    raise RuntimeError(f"unsupported store {w:08x}")
                self.mem[word_addr] = value & 0xFFFFFFFF
                self.pc += 1
            elif opcode == 0x63:
                imm = (((w >> 31) & 1) << 12) | (((w >> 25) & 0x3F) << 5) | \
                      (((w >> 8) & 0xF) << 1) | (((w >> 7) & 1) << 11)
                imm = sext(imm, 13)
                a, b = self.r[rs1], self.r[rs2]
                sa, sb = i32(a), i32(b)
                taken = {
                    0: a == b,
                    1: a != b,
                    4: sa < sb,
                    5: sa >= sb,
                    6: (a & 0xFFFFFFFF) < (b & 0xFFFFFFFF),
                    7: (a & 0xFFFFFFFF) >= (b & 0xFFFFFFFF),
                }.get(funct3)
                if taken is None:
                    raise RuntimeError(f"unsupported branch {w:08x}")
                self.pc = self.pc + (imm >> 2) if taken else self.pc + 1
            elif opcode == 0x37:
                self.wr(rd, ((w >> 12) & 0xFFFFF) << 12)
                self.pc += 1
            elif opcode == 0x17:
                self.wr(rd, self.pc * 4 + (((w >> 12) & 0xFFFFF) << 12))
                self.pc += 1
            elif opcode == 0x6F:
                imm = (((w >> 31) & 1) << 20) | (((w >> 21) & 0x3FF) << 1) | \
                      (((w >> 20) & 1) << 11) | (((w >> 12) & 0xFF) << 12)
                imm = sext(imm, 21)
                self.wr(rd, self.pc * 4 + 4)
                self.pc += imm >> 2
            elif opcode == 0x67 and funct3 == 0:
                target = (self.r[rs1] + imm_i) >> 2
                self.wr(rd, self.pc * 4 + 4)
                self.pc = target
            elif opcode == 0x5B:
                return
            else:
                raise RuntimeError(f"unsupported instruction {w:08x} at pc={self.pc}")
        raise RuntimeError("step limit exceeded")


def load_text(obj):
    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as f:
        binpath = f.name
    try:
        subprocess.run([OBJCOPY, "-O", "binary", "--only-section=.text",
                        obj, binpath], check=True)
        raw = open(binpath, "rb").read()
    finally:
        os.unlink(binpath)
    return list(struct.unpack("<%dI" % (len(raw) // 4), raw))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("obj")
    ap.add_argument("--test", choices=["vecadd", "matmul", "shift", "mem"], required=True)
    args = ap.parse_args()

    program = load_text(args.obj)
    mem = {}
    if args.test == "vecadd":
        for i in range(8):
            mem[i] = i
            mem[8 + i] = i
        for blk in range(2):
            for tid in range(4):
                Cpu(program, mem, blk, 4, tid).run()
        got = [mem.get(16 + i, 0) for i in range(8)]
        want = [2 * i for i in range(8)]
    elif args.test == "matmul":
        for i, v in enumerate([1, 2, 3, 4] + [1, 2, 3, 4]):
            mem[i] = v
        for tid in range(4):
            Cpu(program, mem, 0, 4, tid).run()
        got = [mem.get(8 + i, 0) for i in range(4)]
        want = [7, 10, 15, 22]
    elif args.test == "shift":
        data = [1, 0xFFFFFFF8, 0x7FFFFFFF, 0x80000000, 1, 2, 3, 4]
        for i, v in enumerate(data):
            mem[i] = v
        for tid in range(4):
            Cpu(program, mem, 0, 4, tid).run()
        a = data[0:4]
        sh = data[4:8]
        want = []
        want += [u32(v << 2) for v in a]
        want += [u32(i32(v) >> 1) for v in a]
        want += [u32(v) >> 1 for v in a]
        want += [u32(v << (n & 31)) for v, n in zip(a, sh)]
        want += [u32(i32(v) >> (n & 31)) for v, n in zip(a, sh)]
        want += [u32(v) >> (n & 31) for v, n in zip(a, sh)]
        got = [mem.get(8 + i, 0) for i in range(24)]
    else:  # mem
        data = [(0x80017F80 + i * 0x10101) & 0xFFFFFFFF for i in range(4)]
        for i, v in enumerate(data):
            mem[i] = v
        for tid in range(4):
            Cpu(program, mem, 0, 4, tid).run()
        want = []
        want += [u32(i32(sext(v & 0xFF, 8))) for v in data]
        want += [(v >> 8) & 0xFF for v in data]
        want += [u32(i32(sext((v >> 16) & 0xFFFF, 16))) for v in data]
        want += [(v >> 16) & 0xFFFF for v in data]
        got = []
        for base in (16, 20, 24, 28):
            got += [mem.get(base + i, 0) for i in range(4)]

    print(f"{args.test}: got {got}, want {want}, {'OK' if got == want else 'FAIL'}")
    return 0 if got == want else 1


if __name__ == "__main__":
    raise SystemExit(main())
