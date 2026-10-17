#!/usr/bin/env python3
"""Translate the subset of RISC-V assembly emitted by clang to Abyss assembly.

Abyss is RISC-V-compatible for the instructions it implements.  This
translator only handles the instructions needed by the restricted C subset
described in README.md; anything else is rejected instead of silently
producing wrong code.
"""

import re
import sys

REG = {
    "zero": "x0", "x0": "x0",
    "ra": "R1", "x1": "R1",
    "sp": "R2", "x2": "R2",
    "gp": "R3", "x3": "R3",
    "tp": "R4", "x4": "R4",
    "t0": "R5", "x5": "R5",
    "t1": "R6", "x6": "R6",
    "t2": "R7", "x7": "R7",
    "s0": "R8", "fp": "R8", "x8": "R8",
    "s1": "R9", "x9": "R9",
    "a0": "R10", "x10": "R10",
    "a1": "R11", "x11": "R11",
    "a2": "R12", "x12": "R12",
    "a3": "R13", "x13": "R13",
    "a4": "R14", "x14": "R14",
    "a5": "R15", "x15": "R15",
    "a6": "R16", "x16": "R16",
    "a7": "R17", "x17": "R17",
    "s2": "R18", "x18": "R18",
    "s3": "R19", "x19": "R19",
    "s4": "R20", "x20": "R20",
    "s5": "R21", "x21": "R21",
    "s6": "R22", "x22": "R22",
    "s7": "R23", "x23": "R23",
    "s8": "R24", "x24": "R24",
    "s9": "R25", "x25": "R25",
    "s10": "R26", "x26": "R26",
    "s11": "R27", "x27": "R27",
    "t3": "R28", "x28": "R28",
    "t4": "R29", "x29": "R29",
    "t5": "R30", "x30": "R30",
    "t6": "R31", "x31": "R31",
}


def reg(name):
    name = name.strip()
    if name in REG:
        return REG[name]
    if name.startswith("x") and name[1:].isdigit():
        n = int(name[1:])
        return "x0" if n == 0 else f"R{n}"
    raise ValueError(f"unknown register: {name}")


def parse_imm(text):
    text = text.strip()
    if text.startswith("#"):
        text = text[1:]
    return int(text, 0)


def split_ops(text):
    return [x.strip() for x in text.split(",") if x.strip()]


def parse_mem(text):
    m = re.fullmatch(r"(-?(?:0x[0-9a-fA-F]+|\d+))\(([A-Za-z0-9_.]+)\)", text.strip())
    if not m:
        raise ValueError(f"unsupported memory operand: {text}")
    return m.group(2), parse_imm(m.group(1))


def emit_li(rd, imm, out):
    imm &= 0xFFFFFFFF
    signed = imm if imm < 0x80000000 else imm - 0x100000000
    if -2048 <= signed <= 2047:
        out.append(f"ADDI {rd}, x0, #{signed}")
        return
    hi = ((imm + 0x800) >> 12) & 0xFFFFF
    lo = imm - (hi << 12)
    if lo >= 0x800:
        lo -= 0x1000
    out.append(f"LUI {rd}, {hi}")
    if lo:
        out.append(f"ADDI {rd}, {rd}, #{lo}")


def translate(text):
    out = []
    slt_id = 0

    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue

        if line.endswith(":"):
            out.append(line)
            continue

        if line.startswith("."):
            if line == ".text":
                out.append(".text")
            # Drop .attribute/.file/.globl/.p2align/.type/.size/.ident/
            # .section/.addrsig/.cfi_*/.option and other directives.
            continue

        parts = line.split(None, 1)
        mnem = parts[0].lower()
        rest = parts[1] if len(parts) > 1 else ""
        ops = split_ops(rest)

        if mnem == "mv":
            out.append(f"ADDI {reg(ops[0])}, {reg(ops[1])}, #0")
        elif mnem == "li":
            emit_li(reg(ops[0]), parse_imm(ops[1]), out)
        elif mnem == "nop":
            out.append("ADDI x0, x0, #0")
        elif mnem == "ret":
            out.append("JALR x0, 0(R1)")
        elif mnem == "j":
            out.append(f"JAL x0, {ops[0]}")
        elif mnem in ("call", "tail"):
            rd = "R1" if mnem == "call" else "x0"
            out.append(f"JAL {rd}, {ops[0]}")
        elif mnem in ("beqz", "bnez", "blez", "bgez", "bltz", "bgtz"):
            rs = reg(ops[0])
            lab = ops[1]
            if mnem == "beqz":
                out.append(f"BEQ {rs}, x0, {lab}")
            elif mnem == "bnez":
                out.append(f"BNE {rs}, x0, {lab}")
            elif mnem == "blez":
                out.append(f"BGE x0, {rs}, {lab}")
            elif mnem == "bgez":
                out.append(f"BGE {rs}, x0, {lab}")
            elif mnem == "bltz":
                out.append(f"BLT {rs}, x0, {lab}")
            else:  # bgtz
                out.append(f"BLT x0, {rs}, {lab}")
        elif mnem in ("add", "sub", "mul", "div"):
            rd, rs1, rs2 = (reg(x) for x in ops[:3])
            out.append(f"{mnem.upper()} {rd}, {rs1}, {rs2}")
        elif mnem == "rem":
            rd, rs1, rs2 = (reg(x) for x in ops[:3])
            # R26 is reserved as a translator scratch register.
            out.append(f"DIV R26, {rs1}, {rs2}")
            out.append(f"MUL R26, R26, {rs2}")
            out.append(f"SUB {rd}, {rs1}, R26")
        elif mnem == "addi":
            rd, rs1 = reg(ops[0]), reg(ops[1])
            out.append(f"ADDI {rd}, {rs1}, #{parse_imm(ops[2])}")
        elif mnem in ("lw", "sw"):
            if mnem == "lw":
                rd = reg(ops[0])
                base, off = parse_mem(ops[1])
                out.append(f"LDR {rd}, {off}({reg(base)})")
            else:
                rs2 = reg(ops[0])
                base, off = parse_mem(ops[1])
                out.append(f"STR {rs2}, {off}({reg(base)})")
        elif mnem in ("beq", "bne", "blt", "bge", "bltu", "bgeu"):
            rs1, rs2 = reg(ops[0]), reg(ops[1])
            out.append(f"{mnem.upper()} {rs1}, {rs2}, {ops[2]}")
        elif mnem in ("bgt", "ble", "bgtu", "bleu"):
            rs1, rs2 = reg(ops[0]), reg(ops[1])
            table = {"bgt": "BLT", "ble": "BGE", "bgtu": "BLTU", "bleu": "BGEU"}
            out.append(f"{table[mnem]} {rs2}, {rs1}, {ops[2]}")
        elif mnem == "lui":
            out.append(f"LUI {reg(ops[0])}, {parse_imm(ops[1])}")
        elif mnem == "auipc":
            out.append(f"AUIPC {reg(ops[0])}, {parse_imm(ops[1])}")
        elif mnem == "jal":
            if len(ops) == 1:
                out.append(f"JAL R1, {ops[0]}")
            else:
                out.append(f"JAL {reg(ops[0])}, {ops[1]}")
        elif mnem == "jalr":
            if len(ops) == 1:
                out.append(f"JALR R1, 0({reg(ops[0])})")
            elif len(ops) == 3:
                out.append(f"JALR {reg(ops[0])}, {parse_imm(ops[2])}({reg(ops[1])})")
            else:
                rd = reg(ops[0])
                base, off = parse_mem(ops[1])
                out.append(f"JALR {rd}, {off}({reg(base)})")
        elif mnem in ("slt", "sltu"):
            rd, rs1, rs2 = (reg(x) for x in ops[:3])
            lab = f".Labyss_slt_{slt_id}"
            slt_id += 1
            bcc = "BGE" if mnem == "slt" else "BGEU"
            out.append("ADDI R24, x0, #0")
            out.append(f"{bcc} {rs1}, {rs2}, {lab}")
            out.append("ADDI R24, x0, #1")
            out.append(f"{lab}:")
            out.append(f"ADDI {rd}, R24, #0")
        elif mnem in ("slti", "sltiu"):
            rd, rs1 = reg(ops[0]), reg(ops[1])
            emit_li("R25", parse_imm(ops[2]), out)
            lab = f".Labyss_slt_{slt_id}"
            slt_id += 1
            bcc = "BGE" if mnem == "slti" else "BGEU"
            out.append("ADDI R24, x0, #0")
            out.append(f"{bcc} {rs1}, R25, {lab}")
            out.append("ADDI R24, x0, #1")
            out.append(f"{lab}:")
            out.append(f"ADDI {rd}, R24, #0")
        elif mnem in ("slli", "srli", "srai"):
            rd, rs1 = reg(ops[0]), reg(ops[1])
            sh = parse_imm(ops[2])
            if not 0 <= sh < 32:
                raise ValueError(f"{mnem}: shift amount must be 0..31, got {sh}")
            # Abyss shift-immediates take the raw shamt (no '#'):
            #   SLLI/SRLI/SRAI rd, rs1, shamt
            out.append(f"{mnem.upper()} {rd}, {rs1}, {sh}")
        elif mnem in ("sll", "srl", "sra"):
            rd, rs1, rs2 = (reg(x) for x in ops[:3])
            out.append(f"{mnem.upper()} {rd}, {rs1}, {rs2}")
        elif mnem == "andi" and len(ops) == 3 and reg(ops[0]) == "R2" and \
                parse_imm(ops[2]) == -16:
            # SP starts 16-byte aligned and frame sizes are multiples of 16.
            out.append("# dropped: andi sp, sp, -16")
        else:
            raise ValueError(f"unsupported instruction: {line}")

    return "\n".join(out) + "\n"


def main():
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} input.s output.s", file=sys.stderr)
        return 1
    with open(sys.argv[1]) as f:
        text = f.read()
    try:
        result = translate(text)
    except ValueError as e:
        print(f"riscv2abyss: {e}", file=sys.stderr)
        return 1
    with open(sys.argv[2], "w") as f:
        f.write(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
