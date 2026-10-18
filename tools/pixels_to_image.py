"""Convert Abyss framebuffer words into PNG/PPM images.

The framebuffer format used by the Abyss tests is one 32-bit word per pixel:

    0x00RRGGBB

Only the low 24 bits are used.  The rasterization test stores:

    blue  (edge)  = 0x0000FF
    green (center)= 0x00FF00

This module uses only the Python standard library, so no Pillow dependency is
needed.  It can be used either as a library from a cocotb test or from the
command line.
"""

from __future__ import annotations

import argparse
import struct
import zlib
from pathlib import Path
from typing import Iterable, Sequence


def _rgb(pixel: int) -> tuple[int, int, int]:
    value = int(pixel) & 0xFFFFFFFF
    return (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF


def pixels_to_rgb_bytes(pixels: Sequence[int], width: int, height: int) -> bytes:
    if width <= 0 or height <= 0:
        raise ValueError("width and height must be positive")
    if len(pixels) < width * height:
        raise ValueError(
            f"need {width * height} pixels, got {len(pixels)}")
    out = bytearray()
    for value in pixels[: width * height]:
        out.extend(_rgb(value))
    return bytes(out)


def _png_chunk(tag: bytes, data: bytes) -> bytes:
    crc = zlib.crc32(tag + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)


def save_png(pixels: Sequence[int], width: int, height: int,
             path: str | Path) -> Path:
    """Write RGB pixels as a PNG file and return the output path."""
    rgb = pixels_to_rgb_bytes(pixels, width, height)
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # PNG filter: None
        raw.extend(rgb[y * width * 3:(y + 1) * width * 3])

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    png = (b"\x89PNG\r\n\x1a\n" +
           _png_chunk(b"IHDR", ihdr) +
           _png_chunk(b"IDAT", zlib.compress(bytes(raw), 9)) +
           _png_chunk(b"IEND", b""))

    output = Path(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(png)
    return output


def save_ppm(pixels: Sequence[int], width: int, height: int,
             path: str | Path) -> Path:
    """Write RGB pixels as a binary PPM (P6) file."""
    rgb = pixels_to_rgb_bytes(pixels, width, height)
    output = Path(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(
        f"P6\n{width} {height}\n255\n".encode("ascii") + rgb)
    return output


def save_image(pixels: Sequence[int], width: int, height: int,
               path: str | Path) -> Path:
    output = Path(path)
    if output.suffix.lower() == ".ppm":
        return save_ppm(pixels, width, height, output)
    return save_png(pixels, width, height, output)


def save_pixel_dump(pixels: Sequence[int], path: str | Path) -> Path:
    """Write pixels as raw little-endian 32-bit words."""
    output = Path(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(struct.pack(f"<{len(pixels)}I",
                                   *(int(p) & 0xFFFFFFFF for p in pixels)))
    return output


def memory_pixels(memory: object, count: int, base: int = 0) -> list[int]:
    """Read `count` words from a test helper Memory object or dict."""
    source = getattr(memory, "memory", memory)
    return [int(source.get(base + i, 0)) for i in range(count)]


def read_pixel_file(path: str | Path) -> list[int]:
    """Read pixels from a raw little-endian .bin or a text/hex word file."""
    source = Path(path)
    if source.suffix.lower() == ".bin":
        raw = source.read_bytes()
        if len(raw) % 4:
            raise ValueError("binary pixel file size must be a multiple of 4")
        return list(struct.unpack(f"<{len(raw) // 4}I", raw))

    pixels: list[int] = []
    for line in source.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        for token in line.replace(",", " ").split():
            pixels.append(int(token, 0))
    return pixels


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Convert Abyss framebuffer words to PNG or PPM")
    parser.add_argument("input", help="raw .bin or text file of 0xRRGGBB words")
    parser.add_argument("-o", "--output", default="framebuffer.png")
    parser.add_argument("--width", type=int, default=16)
    parser.add_argument("--height", type=int, default=16)
    args = parser.parse_args(list(argv) if argv is not None else None)

    pixels = read_pixel_file(args.input)
    out = save_image(pixels, args.width, args.height, args.output)
    print(f"wrote {out} ({args.width}x{args.height}, {len(pixels)} pixels)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
