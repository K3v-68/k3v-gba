#!/usr/bin/env python3
"""Run reset-drain-gate regressions (host reset must not abandon flash bursts)."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

TEST_DIR = Path(__file__).resolve().parent
REPO_ROOT = TEST_DIR.parents[1]


def resolve_tool(explicit: str | None, name: str) -> str:
    candidate = explicit or shutil.which(name)
    if not candidate:
        raise RuntimeError(f"{name} was not found; pass --{name} explicitly")
    return str(Path(candidate).resolve())


def run(command: list[str]) -> None:
    print("+", " ".join(command), flush=True)
    subprocess.run(command, cwd=REPO_ROOT, check=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iverilog")
    parser.add_argument("--vvp")
    args = parser.parse_args()
    iverilog = resolve_tool(args.iverilog, "iverilog")
    vvp = resolve_tool(args.vvp, "vvp")

    cases = (
        ("mid-sector-erase", ()),
        ("early-in-erase", ("tb_reset_drain_gate.RESET_AT_BYTE=1",)),
        ("last-byte-of-erase", ("tb_reset_drain_gate.RESET_AT_BYTE=4090",)),
        ("slow-psram", ("tb_reset_drain_gate.BYTE_CYCLES=40",)),
        ("idle-bus", ("tb_reset_drain_gate.RESET_BEFORE_START=1",)),
        ("busy-bus-stays-deferred", ("tb_reset_drain_gate.WEDGE=1",)),
    )
    build_dir = Path(tempfile.mkdtemp(prefix="k3v-gba-reset-drain-"))
    try:
        for name, parameters in cases:
            output = build_dir / f"{name}.vvp"
            command = [iverilog, "-g2012", "-Wall", "-s", "tb_reset_drain_gate"]
            for parameter in parameters:
                command.extend(("-P", parameter))
            command.extend(
                (
                    "-o",
                    str(output),
                    str(REPO_ROOT / "src/fpga/core/reset_drain_gate.sv"),
                    str(TEST_DIR / "tb_reset_drain_gate.sv"),
                )
            )
            run(command)
            result = subprocess.run(
                [vvp, str(output)], cwd=REPO_ROOT, capture_output=True, text=True
            )
            print(result.stdout, end="")
            if result.returncode != 0 or "RESET DRAIN PASS" not in result.stdout:
                print(result.stderr, file=sys.stderr)
                raise RuntimeError(f"case {name} failed")
    finally:
        shutil.rmtree(build_dir, ignore_errors=True)
    print("Reset drain gate regressions passed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"reset-drain test failure: {error}", file=sys.stderr)
        raise SystemExit(1)
