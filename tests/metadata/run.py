#!/usr/bin/env python3
"""Compile and run the boot-metadata regression."""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


TEST_DIR = Path(__file__).resolve().parent
REPO_ROOT = TEST_DIR.parents[1]


def check_table_manifest() -> None:
    """Ratchet the production ROM to exactly 26 prefix + 44 exact records."""
    source = (REPO_ROOT / "src/fpga/core/cart_quirks.sv").read_text(
        encoding="utf-8"
    )
    assignments = re.findall(
        r"quirk_rom\[\s*(\d+)\s*\]\s*=\s*\{\s*1'b([01])\s*,", source
    )
    indices = [int(index) for index, _ in assignments]
    prefix_count = sum(kind == "1" for _, kind in assignments)
    exact_count = sum(kind == "0" for _, kind in assignments)
    if indices != list(range(70)):
        raise RuntimeError(
            f"cart quirk ROM indices changed: expected 0..69, got {indices}"
        )
    if (prefix_count, exact_count) != (26, 44):
        raise RuntimeError(
            "cart quirk manifest changed: "
            f"expected 26 prefix + 44 exact, got {prefix_count} + {exact_count}"
        )

    core_source = (REPO_ROOT / "src/fpga/core/core_top.sv").read_text(
        encoding="utf-8"
    )
    if ".quirks_ready  ( quirks_ready )" not in core_source:
        raise RuntimeError("core_top no longer connects cart_quirks readiness")
    if "~quirks_ready" not in core_source:
        raise RuntimeError("core_top no longer holds GBA reset through quirk lookup")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iverilog", help="explicit Icarus Verilog executable")
    parser.add_argument("--vvp", help="explicit Icarus runtime executable")
    args = parser.parse_args()

    compiler = args.iverilog or shutil.which("iverilog")
    runtime = args.vvp or shutil.which("vvp")
    if not compiler or not runtime:
        parser.error("iverilog and vvp must both be available")

    check_table_manifest()

    environment = os.environ.copy()
    portable_paths: list[str] = []
    for tool in (compiler, runtime):
        binary_dir = Path(tool).resolve().parent
        portable_paths.append(str(binary_dir))
        library_dir = binary_dir.parent / "lib"
        if library_dir.is_dir():
            portable_paths.append(str(library_dir))
    environment["PATH"] = os.pathsep.join(
        [*dict.fromkeys(portable_paths), environment.get("PATH", "")]
    )

    with tempfile.TemporaryDirectory(prefix="k3v-gba-metadata-") as work_dir:
        output = Path(work_dir) / "boot_metadata.vvp"
        subprocess.run(
            [
                compiler,
                "-g2012",
                "-Wall",
                "-s",
                "tb_boot_metadata",
                "-o",
                str(output),
                str(REPO_ROOT / "src/fpga/core/save_type_detector.sv"),
                str(REPO_ROOT / "src/fpga/core/cart_quirks.sv"),
                str(TEST_DIR / "tb_boot_metadata.sv"),
            ],
            cwd=REPO_ROOT,
            env=environment,
            check=True,
        )
        subprocess.run(
            [runtime, str(output)], cwd=REPO_ROOT, env=environment, check=True
        )

    print("Boot-metadata regression passed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as error:
        print(f"boot-metadata test failure: {error}", file=sys.stderr)
        raise SystemExit(1)
