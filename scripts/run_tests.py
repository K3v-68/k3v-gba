#!/usr/bin/env python3
"""Run every deterministic K3V GBA regression and project validation check."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


def find_tool(root: Path, name: str, candidates: tuple[str, ...]) -> str:
    installed = shutil.which(name)
    if installed:
        return installed
    for candidate in candidates:
        path = root / candidate
        if path.is_file():
            return str(path.resolve())
    raise RuntimeError(f"required simulator not found: {name}")


def run(root: Path, command: list[str]) -> None:
    print("+", " ".join(command), flush=True)
    subprocess.run(command, cwd=root, check=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--quick",
        action="store_true",
        help="use short save fixtures instead of full 128 KiB release fixtures",
    )
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    python = sys.executable
    executable_suffix = ".exe" if sys.platform == "win32" else ""
    ghdl = find_tool(
        root,
        "ghdl",
        (f".toolchain/simulators/ghdl-6.0.0/bin/ghdl{executable_suffix}",),
    )
    iverilog = find_tool(
        root,
        "iverilog",
        (
            f".toolchain/simulators/oss-cad-suite-20260806/oss-cad-suite/bin/iverilog{executable_suffix}",
        ),
    )
    vvp = find_tool(
        root,
        "vvp",
        (
            f".toolchain/simulators/oss-cad-suite-20260806/oss-cad-suite/bin/vvp{executable_suffix}",
        ),
    )

    run(root, [python, "scripts/validate_project.py"])
    run(root, [python, "scripts/build_artwork.py", "--check"])
    run(root, [python, "tests/resources/run.py"])
    run(
        root,
        [
            python,
            "tests/metadata/run.py",
            "--iverilog",
            iverilog,
            "--vvp",
            vvp,
        ],
    )
    run(
        root,
        [
            python,
            "tests/rtc/run.py",
            "--require-ghdl",
            "--ghdl",
            ghdl,
            "--require-iverilog",
            "--iverilog",
            iverilog,
            "--vvp",
            vvp,
        ],
    )
    run(
        root,
        [
            python,
            "tests/bridge/run.py",
            "--iverilog",
            iverilog,
            "--vvp",
            vvp,
        ],
    )
    run(
        root,
        [
            python,
            "tests/loader/run.py",
            "--iverilog",
            iverilog,
            "--vvp",
            vvp,
        ],
    )
    save_command = [
        python,
        "tests/save/run.py",
        "--simulator",
        "iverilog",
        "--iverilog",
        iverilog,
        "--vvp",
        vvp,
    ]
    save_command.append("--bytes=4096" if args.quick else "--full")
    run(root, save_command)
    run(
        root,
        [python, "tests/psram/run.py", "--iverilog", iverilog, "--vvp", vvp],
    )
    print("All K3V GBA regressions passed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f"test suite failure: {error}", file=sys.stderr)
        raise SystemExit(1)
