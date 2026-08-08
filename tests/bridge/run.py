#!/usr/bin/env python3
"""Compile and run the Pocket PMP bridge pipeline regression."""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


TEST_DIR = Path(__file__).resolve().parent
REPO_ROOT = TEST_DIR.parents[1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iverilog", help="explicit Icarus Verilog executable")
    parser.add_argument("--vvp", help="explicit Icarus runtime executable")
    args = parser.parse_args()

    compiler = args.iverilog or shutil.which("iverilog")
    runtime = args.vvp or shutil.which("vvp")
    if not compiler or not runtime:
        parser.error("iverilog and vvp must both be available")

    portable_paths: list[str] = []
    for tool in (compiler, runtime):
        binary_dir = Path(tool).resolve().parent
        portable_paths.append(str(binary_dir))
        library_dir = binary_dir.parent / "lib"
        if library_dir.is_dir():
            portable_paths.append(str(library_dir))
    os.environ["PATH"] = os.pathsep.join(
        [*dict.fromkeys(portable_paths), os.environ.get("PATH", "")]
    )

    build_dir = Path(tempfile.mkdtemp(prefix="k3v-gba-bridge-test-"))
    output = build_dir / "bridge_pipeline.vvp"
    sources = [
        REPO_ROOT / "src" / "fpga" / "apf" / "common.v",
        REPO_ROOT / "src" / "fpga" / "apf" / "io_bridge_peripheral.v",
        TEST_DIR / "tb_io_bridge_pipeline.sv",
    ]

    try:
        subprocess.run(
            [compiler, "-g2012", "-Wall", "-s", "tb_io_bridge_pipeline",
             "-o", str(output), *(str(path) for path in sources)],
            cwd=REPO_ROOT,
            check=True,
        )
        subprocess.run([runtime, str(output)], cwd=REPO_ROOT, check=True)
    finally:
        shutil.rmtree(build_dir, ignore_errors=True)

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as error:
        print(f"bridge pipeline test failure: {error}", file=sys.stderr)
        raise SystemExit(1)
