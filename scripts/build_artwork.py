#!/usr/bin/env python3
"""Build and validate K3V GBA artwork in Analogue Pocket formats."""

from __future__ import annotations

import argparse
import io
import sys
from pathlib import Path

from PIL import Image, ImageOps


ICON_SIZE = 36
PIXEL_GRID = 18
MARK_LIMIT = 16


def crop_to_mark(image: Image.Image) -> Image.Image:
    gray = ImageOps.grayscale(image)
    mask = gray.point(lambda value: 255 if value < 245 else 0)
    bounds = mask.getbbox()
    if bounds is None:
        raise ValueError("master artwork contains no dark mark")
    return gray.crop(bounds)


def build_icon(master: Image.Image) -> Image.Image:
    mark = crop_to_mark(master)
    mark.thumbnail((MARK_LIMIT, MARK_LIMIT), Image.Resampling.LANCZOS)
    mark = mark.point(lambda value: 0 if value < 176 else 255, mode="1").convert("L")

    pixel_icon = Image.new("L", (PIXEL_GRID, PIXEL_GRID), 255)
    offset = ((PIXEL_GRID - mark.width) // 2, (PIXEL_GRID - mark.height) // 2)
    pixel_icon.paste(mark, offset)
    return pixel_icon.resize((ICON_SIZE, ICON_SIZE), Image.Resampling.NEAREST)


def encode_pocket_monochrome(image: Image.Image) -> bytes:
    if image.size != (ICON_SIZE, ICON_SIZE):
        raise ValueError(f"icon must be {ICON_SIZE}x{ICON_SIZE}, found {image.size}")

    # Analogue stores monochrome graphics rotated 90 degrees counter-clockwise.
    stored = image.transpose(Image.Transpose.ROTATE_90)
    payload = bytearray()
    pixels = (
        stored.get_flattened_data()
        if hasattr(stored, "get_flattened_data")
        else stored.getdata()
    )
    for brightness in pixels:
        payload.extend((int(brightness), 0))
    expected = ICON_SIZE * ICON_SIZE * 2
    if len(payload) != expected:
        raise AssertionError(f"encoded icon is {len(payload)} bytes, expected {expected}")
    return bytes(payload)


def png_bytes(image: Image.Image, *, scale: int = 1) -> bytes:
    if scale != 1:
        image = image.resize(
            (image.width * scale, image.height * scale), Image.Resampling.NEAREST
        )
    output = io.BytesIO()
    image.save(output, format="PNG", optimize=True)
    return output.getvalue()


def check_or_write(path: Path, expected: bytes, check: bool) -> None:
    if check:
        actual = path.read_bytes() if path.is_file() else None
        if actual != expected:
            raise ValueError(f"generated artwork is stale or missing: {path}")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(expected)


def check_or_write_png(path: Path, expected: Image.Image, check: bool) -> None:
    """Check PNG image content without depending on platform compression bytes."""
    if check:
        if not path.is_file():
            raise ValueError(f"generated artwork is stale or missing: {path}")
        try:
            with Image.open(path) as actual:
                actual.load()
                matches = (
                    actual.size == expected.size
                    and actual.mode == expected.mode
                    and actual.tobytes() == expected.tobytes()
                )
        except OSError as error:
            raise ValueError(f"generated artwork is unreadable: {path}") from error
        if not matches:
            raise ValueError(f"generated artwork is stale or missing: {path}")
        return

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png_bytes(expected))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--project-root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify committed outputs instead of rewriting them",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = args.project_root.resolve()
    master_path = root / "artwork/k3v-gba-emblem-master.png"
    icon_png = root / "artwork/k3v-gba-icon-36.png"
    preview_png = root / "artwork/k3v-gba-icon-preview.png"
    icon_bin = root / "pkg/Cores/K3V.GBA/icon.bin"

    try:
        with Image.open(master_path) as master:
            icon = build_icon(master)
        preview = icon.resize(
            (icon.width * 12, icon.height * 12), Image.Resampling.NEAREST
        )
        check_or_write_png(icon_png, icon, args.check)
        check_or_write_png(preview_png, preview, args.check)
        check_or_write(icon_bin, encode_pocket_monochrome(icon), args.check)
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    action = "Verified" if args.check else "Generated"
    print(f"{action}: {icon_bin} ({ICON_SIZE * ICON_SIZE * 2} bytes)")
    print(f"{action}: {icon_png}")
    print(f"{action}: {preview_png}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
