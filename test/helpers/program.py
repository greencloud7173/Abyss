"""Load Abyss test binaries and run a cocotb test case.

The test entry files only need to provide:

* the binary artifact name (for example ``"matadd"``), and
* the original data-memory contents plus the thread count.

Everything else (program memory, data memory, clock/reset, run loop) is
handled here.
"""

from __future__ import annotations

import os
import struct
import subprocess
import tempfile
from collections import Counter
from pathlib import Path

from cocotb.triggers import ReadOnly, RisingEdge

from .format import format_cycle, format_instruction
from .logger import logger
from .memory import Memory
from .setup import setup

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OBJCOPY = "/home/greencloud7173/llvm-project/build/bin/llvm-objcopy"


def _find_binary(name: str, case: str | None = None) -> Path:
    """Resolve a binary name to a file.

    Accepted forms:
      * an absolute/relative path to a ``.bin`` or ``.o`` file;
      * a bare artifact name such as ``"matadd"``, looked up in
        ``test/<case>/build/`` and then ``test/*/build/``.
    """
    path = Path(name)
    if path.suffix in (".bin", ".o"):
        candidate = path if path.is_absolute() else REPO_ROOT / path
        if candidate.is_file():
            return candidate
        # Allow passing "matadd.bin" while still searching the build dirs.
        name = path.stem

    patterns: list[str] = []
    if case:
        patterns += [
            f"test/{case}/build/{name}.bin",
            f"test/{case}/build/{name}.o",
        ]
    patterns += [
        f"test/*/build/{name}.bin",
        f"test/*/build/{name}.o",
    ]

    for pattern in patterns:
        matches = sorted(REPO_ROOT.glob(pattern))
        if matches:
            # Prefer the flat binary produced by the per-case Makefile.
            bins = [match for match in matches if match.suffix == ".bin"]
            return bins[0] if bins else matches[0]

    hint = case or "<case>"
    raise FileNotFoundError(
        f"binary not found: {name!r}; run `make test {hint}` first"
    )


def _extract_text(obj: Path) -> bytes:
    """Extract .text from an ELF object as a flat little-endian blob."""
    objcopy = os.environ.get("LLVM_OBJCOPY", DEFAULT_OBJCOPY)
    if not Path(objcopy).is_file():
        raise FileNotFoundError(
            f"llvm-objcopy not found at {objcopy}; "
            "set LLVM_OBJCOPY or use a .bin file"
        )

    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as tmp:
        output = Path(tmp.name)
    try:
        subprocess.run(
            [
                objcopy,
                "-O",
                "binary",
                "--only-section=.text",
                str(obj),
                str(output),
            ],
            check=True,
        )
        return output.read_bytes()
    finally:
        output.unlink(missing_ok=True)


def load_program(name: str, case: str | None = None) -> list[int]:
    """Load an Abyss program and return its 32-bit words."""
    path = _find_binary(name, case)
    raw = path.read_bytes() if path.suffix == ".bin" else _extract_text(path)

    if not raw:
        raise ValueError(f"empty program: {path}")
    if len(raw) % 4:
        raise ValueError(
            f"program size is not a multiple of 4 bytes: {path} ({len(raw)} bytes)"
        )

    return list(struct.unpack(f"<{len(raw) // 4}I", raw))


def _to_int(value) -> int:
    value = getattr(value, "value", value)
    if isinstance(value, str):
        return int(value, 2)
    return int(value)


def _new_profile() -> dict:
    return {
        "core_state": Counter(),
        "issued_instr": Counter(),
        "lsu_wait_threads": 0,
    }


def _sample_profile(dut, profile: dict) -> None:
    """Sample one cycle of core and LSU state."""
    for core in dut.cores:
        state = _to_int(core.core_instance.core_state)
        profile["core_state"][state] += 1

        if state == 6:  # UPDATE: one multi-threaded instruction retired
            inst = format_instruction(str(core.core_instance.instruction.value))
            mnemonic = inst.split()[0] if inst not in ("-", "") else "NOP"
            profile["issued_instr"][mnemonic] += _to_int(
                core.core_instance.thread_count)

        if state == 4:  # WAIT: count threads blocked in LSU
            profile["lsu_wait_threads"] += sum(
                1 for thread in core.core_instance.threads
                if _to_int(thread.lsu_instance.lsu_state) in (1, 2)
            )


def _profile_report(profile: dict, cycles: int) -> None:
    state_names = {
        0: "IDLE", 1: "FETCH", 2: "DECODE", 3: "REQUEST",
        4: "WAIT", 5: "EXECUTE", 6: "UPDATE", 7: "DONE",
    }
    total_core = sum(profile["core_state"].values()) or 1
    lines = [f"PROFILE cycles={cycles} core_cycles={total_core}"]
    lines.append("core states:")
    for state, count in profile["core_state"].most_common():
        lines.append(f"  {state_names[state]:8s} {count:10d} "
                     f"{100.0 * count / total_core:6.2f}%")
    lines.append("instructions (issued across active threads):")
    for op, count in profile["issued_instr"].most_common(16):
        lines.append(f"  {op:8s} {count:10d}")
    lines.append(f"LSU-blocked thread-cycles: {profile['lsu_wait_threads']}")
    text = "\n".join(lines)
    logger.info(text)
    print(text)


async def run_case(
    dut,
    binary: str,
    *,
    data: list[int],
    threads: int,
    display: int = 0,
    thread_id: int | None = None,
    trace: bool = True,
) -> tuple[Memory, int]:
    """Build and run one test case from a binary name and memory parameters.

    Returns the data memory (so the caller can assert on it) and the number of
    simulated cycles.
    """
    program = load_program(binary)

    program_memory = Memory(
        dut=dut, addr_bits=32, data_bits=32, channels=1, name="program"
    )
    # Data memory channel count follows the RTL (`DATA_MEM_NUM_CHANNELS`) instead
    # of being hard-coded, so widening the SIMD only needs the gpu.sv parameter.
    try:
        data_channels = len(dut.data_mem_read_valid)
    except TypeError:
        data_channels = len(str(dut.data_mem_read_valid.value))
    data_memory = Memory(
        dut=dut, addr_bits=32, data_bits=32, channels=data_channels, name="data"
    )

    await setup(
        dut=dut,
        program_memory=program_memory,
        program=program,
        data_memory=data_memory,
        data=data,
        threads=threads,
    )

    if display:
        data_memory.display(display)

    profile = _new_profile() if os.environ.get("ABYSS_PROFILE") == "1" else None
    cycles = 0
    while dut.done.value != 1:
        data_memory.run()
        program_memory.run()

        await ReadOnly()
        if profile is not None:
            _sample_profile(dut, profile)
        if trace:
            format_cycle(dut, cycles, thread_id=thread_id)

        await RisingEdge(dut.clk)
        cycles += 1

    logger.info(f"{binary}: completed in {cycles} cycles")
    if profile is not None:
        _profile_report(profile, cycles)
    if display:
        data_memory.display(display)

    return data_memory, cycles
