"""Shared verification and image export for the rasterization tests."""

from __future__ import annotations

import re
import sys
from pathlib import Path

from .program import run_case

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from tools.pixels_to_image import memory_pixels, save_pixel_dump, save_png


_DEFAULT_VERTICES = {
    "AX": "RASTER_WIDTH * 789 / 1000",
    "AY": "RASTER_HEIGHT * 364 / 1000",
    "BX": "RASTER_WIDTH * 139 / 1000",
    "BY": "RASTER_HEIGHT * 739 / 1000",
    "CX": "RASTER_WIDTH * 447 / 1000",
    "CY": "RASTER_HEIGHT * 273 / 1000",
}


def _read_vertices(case: str, width: int, height: int):
    """Read RASTER_A*..RASTER_C* overrides from the C source/header."""
    expressions = dict(_DEFAULT_VERTICES)
    paths = [
        REPO_ROOT / "test" / "helpers" / "raster_kernel.h",
        REPO_ROOT / "test" / case / "src" / f"{case}.c",
    ]
    for path in paths:
        if not path.is_file():
            continue
        text = path.read_text()
        for key in expressions:
            match = re.search(
                rf"^\s*#define\s+RASTER_{key}\s+([^\n]+)", text, re.M)
            if match:
                expressions[key] = match.group(1).split("//", 1)[0].strip()

    values = {}
    for key, expr in expressions.items():
        expr = expr.replace("RASTER_WIDTH", str(width))
        expr = expr.replace("RASTER_HEIGHT", str(height))
        try:
            values[key] = int(eval(expr, {"__builtins__": None}, {}))
        except Exception:
            values[key] = int(eval(_DEFAULT_VERTICES[key], {
                "__builtins__": None, "RASTER_WIDTH": width,
                "RASTER_HEIGHT": height}))
    return (values["AX"], values["AY"], values["BX"], values["BY"],
            values["CX"], values["CY"])


def expected_pixel(x: int, y: int, width: int, height: int,
                   vertices=None) -> int:
    """Software model of the kernel's integer edge-function rasterizer."""
    if vertices is None:
        vertices = _read_vertices("raster16x16", width, height)
    ax, ay, bx, by, cx, cy = vertices
    cross = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
    orient = -1 if cross < 0 else 1
    area = abs(cross)

    e0 = orient * ((bx - ax) * (y - ay) - (by - ay) * (x - ax))
    e1 = orient * ((cx - bx) * (y - by) - (cy - by) * (x - bx))
    e2 = orient * ((ax - cx) * (y - cy) - (ay - cy) * (x - cx))

    if e0 < 0 or e1 < 0 or e2 < 0:
        return 0

    m = min(e0, e1, e2)
    t = min(255, (3 * m * 255) // area)
    return (t << 8) | (255 - t)


async def run_raster_case(dut, case: str, width: int, height: int,
                          threads: int) -> tuple[list[int], int]:
    """Run one raster case, check sampled pixels, and write its image files."""
    data_memory, cycles = await run_case(
        dut,
        case,
        data=[],
        threads=threads,
        trace=False,
    )

    pixels = memory_pixels(data_memory, width * height)

    # Export even when an assertion below fails, so the image can be inspected.
    output = REPO_ROOT / "test" / case / "build" / f"{case}.png"
    save_png(pixels, width, height, output)
    save_pixel_dump(pixels, output.with_suffix(".pixels.bin"))

    vertices = _read_vertices(case, width, height)
    samples = {
        (0, 0),
        (width - 1, 0),
        (width // 2, height // 2),
        (width // 2, 1),
        (width // 2, height // 3),
        (1, 1),
        (width - 2, 1),
        (width // 2, height - 2),
    }
    step_x = max(1, width // 7)
    step_y = max(1, height // 7)
    for y in range(0, height, step_y):
        for x in range(0, width, step_x):
            samples.add((x, y))

    for x, y in samples:
        got = pixels[y * width + x]
        want = expected_pixel(x, y, width, height, vertices)
        assert got == want, (
            f"{case}: pixel ({x},{y}) expected 0x{want:08X}, "
            f"got 0x{got:08X}")

    assert any(pixel != 0 for pixel in pixels), (
        f"{case}: no triangle pixels rendered")

    return pixels, cycles
