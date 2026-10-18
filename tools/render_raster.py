#!/usr/bin/env python3
"""DEPRECATED: Python functional simulation is obsolete.

Use the RTL tests instead::

    make test raster16x16
    make test raster128x128

This helper is kept only for historical comparison.  It executes the compiled
kernel on the Python CPU model rather than the RTL, so it must not be used to
validate the GPU implementation or to produce accepted reference images.
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from tools.pixels_to_image import save_image, save_pixel_dump
from tools.run_abyss import Cpu, load_text


def load_program(path: Path) -> list[int]:
    if path.suffix == ".bin":
        raw = path.read_bytes()
        if len(raw) % 4:
            raise ValueError(f"{path}: size is not a multiple of 4")
        return list(struct.unpack(f"<{len(raw) // 4}I", raw))
    return load_text(str(path))


def render(binary: str | Path, width: int, height: int,
           threads: int) -> list[int]:
    if width <= 0 or height <= 0:
        raise ValueError("width and height must be positive")
    if threads <= 0 or threads % 4:
        raise ValueError("threads must be a positive multiple of 4")

    program = load_program(Path(binary))
    memory: dict[int, int] = {}
    iterations = (width * height + threads - 1) // threads

    # The RTL has four threads per block; run every block's four lanes.
    for block in range(threads // 4):
        for thread in range(4):
            Cpu(program, memory, block, 4, thread).run(
                max_steps=2000 + iterations * 200)

    return [memory.get(p, 0) for p in range(width * height)]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Render an Abyss raster binary without the RTL simulator")
    parser.add_argument("binary", help="compiled .bin or .o kernel")
    parser.add_argument("--width", type=int, required=True)
    parser.add_argument("--height", type=int, required=True)
    parser.add_argument(
        "--threads", type=int, default=None,
        help="total launched threads (multiple of 4); must match the kernel's "
             "RASTER_THREADS (default: width for <=128, otherwise 128)")
    parser.add_argument("-o", "--output", default="raster.png")
    parser.add_argument("--pixels", help="also write raw 32-bit pixels here")
    args = parser.parse_args(argv)

    print("WARNING: render_raster.py is deprecated; use the RTL tests.",
          file=sys.stderr)
    threads = args.threads
    if threads is None:
        threads = args.width if args.width <= 128 else 128

    pixels = render(args.binary, args.width, args.height, threads)
    output = save_image(pixels, args.width, args.height, args.output)
    if args.pixels:
        save_pixel_dump(pixels, args.pixels)
    print(f"wrote {output} ({args.width}x{args.height}, {len(pixels)} pixels)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
