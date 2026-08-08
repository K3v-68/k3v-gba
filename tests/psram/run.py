#!/usr/bin/env python3
"""Compile and run the physical PSRAM controller regression."""

from __future__ import annotations

import argparse
import os
import subprocess
import tempfile
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--iverilog", required=True)
    parser.add_argument("--vvp", required=True)
    args = parser.parse_args()

    project_root = Path(__file__).resolve().parents[2]
    suite_bin = Path(args.iverilog).resolve().parent
    suite_root = suite_bin.parent
    environment = os.environ.copy()
    environment["PATH"] = os.pathsep.join(
        (str(suite_bin), str(suite_root / "lib"), environment.get("PATH", ""))
    )

    with tempfile.TemporaryDirectory(prefix="k3v-psram-test-") as temp_dir:
        output = Path(temp_dir) / "tb_psram.vvp"
        compile_command = [
            str(Path(args.iverilog).resolve()),
            "-g2012",
            "-Wall",
            "-Wno-timescale",
            "-s",
            "tb_psram",
            "-o",
            str(output),
            str(project_root / "src/fpga/pocket/psram.sv"),
            str(project_root / "tests/psram/tb_psram.sv"),
        ]
        subprocess.run(compile_command, check=True, cwd=project_root, env=environment)
        subprocess.run(
            [str(Path(args.vvp).resolve()), str(output)],
            check=True,
            cwd=project_root,
            env=environment,
        )

    print("All PSRAM controller regressions passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
