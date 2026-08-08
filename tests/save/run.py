#!/usr/bin/env python3
"""Compile and run the data_unloader save-path regressions."""

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
SOURCES = [
    TEST_DIR / "dcfifo_model.sv",
    REPO_ROOT / "src" / "fpga" / "pocket" / "data_unloader.sv",
    TEST_DIR / "tb_data_unloader.sv",
]


def run(command: list[str]) -> None:
    print("+", " ".join(command), flush=True)
    subprocess.run(command, cwd=REPO_ROOT, check=True)


def compile_iverilog(
    build_dir: Path, compiler: str | None = None, runtime: str | None = None
) -> list[str]:
    compiler = compiler or shutil.which("iverilog")
    runtime = runtime or shutil.which("vvp")
    if not compiler or not runtime:
        raise RuntimeError("iverilog and vvp must both be on PATH")
    output = build_dir / "save_path.vvp"
    run(
        [
            compiler,
            "-g2012",
            "-Wall",
            "-s",
            "tb_data_unloader",
            "-o",
            str(output),
            *(str(source) for source in SOURCES),
        ]
    )
    return [runtime, str(output)]


def compile_verilator(build_dir: Path, compiler: str | None = None) -> list[str]:
    compiler = compiler or shutil.which("verilator")
    if not compiler:
        raise RuntimeError("verilator must be on PATH")
    object_dir = build_dir / "obj_dir"
    executable_name = "save_path_sim"
    run(
        [
            compiler,
            "--binary",
            "--timing",
            "--assert",
            "-Wno-fatal",
            "--top-module",
            "tb_data_unloader",
            "--Mdir",
            str(object_dir),
            "-o",
            executable_name,
            *(str(source) for source in SOURCES),
        ]
    )
    executable = object_dir / executable_name
    if sys.platform == "win32":
        executable = executable.with_suffix(".exe")
    return [str(executable)]


def choose_simulator(
    requested: str, iverilog: str | None, vvp: str | None, verilator: str | None
) -> str:
    if requested != "auto":
        return requested
    if (iverilog or shutil.which("iverilog")) and (vvp or shutil.which("vvp")):
        return "iverilog"
    if verilator or shutil.which("verilator"):
        return "verilator"
    raise RuntimeError("neither Icarus Verilog nor Verilator was found on PATH")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--simulator",
        choices=("auto", "iverilog", "verilator"),
        default="auto",
        help="simulator to use (default: first available, preferring Icarus)",
    )
    size = parser.add_mutually_exclusive_group()
    size.add_argument(
        "--full",
        action="store_true",
        help="run 128 KiB for each of patterned, random, and all-FF fixtures",
    )
    size.add_argument(
        "--bytes",
        type=int,
        default=4096,
        help="bytes per quick fixture (default: 4096)",
    )
    parser.add_argument("--seed", type=int, default=1260203583)
    parser.add_argument("--iverilog", help="explicit Icarus Verilog executable")
    parser.add_argument("--vvp", help="explicit Icarus runtime executable")
    parser.add_argument("--verilator", help="explicit Verilator executable")
    parser.add_argument(
        "--keep-build",
        action="store_true",
        help="keep the temporary simulator build directory",
    )
    args = parser.parse_args()

    explicit_tools = (args.iverilog, args.vvp, args.verilator)
    for tool in (path for path in explicit_tools if path):
        if not Path(tool).resolve().is_file():
            parser.error(f"simulator executable does not exist: {tool}")
    iverilog = str(Path(args.iverilog).resolve()) if args.iverilog else None
    vvp = str(Path(args.vvp).resolve()) if args.vvp else None
    verilator = str(Path(args.verilator).resolve()) if args.verilator else None

    # Portable Windows bundles keep runtime DLLs beside the executable and in
    # a sibling lib directory.  Make those locations visible to child tools
    # without requiring a machine-wide PATH change.
    portable_paths: list[str] = []
    for tool in (iverilog, vvp, verilator):
        if tool:
            binary_dir = Path(tool).parent
            portable_paths.append(str(binary_dir))
            library_dir = binary_dir.parent / "lib"
            if library_dir.is_dir():
                portable_paths.append(str(library_dir))
    if portable_paths:
        os.environ["PATH"] = os.pathsep.join(
            [*dict.fromkeys(portable_paths), os.environ.get("PATH", "")]
        )

    simulator = choose_simulator(args.simulator, iverilog, vvp, verilator)
    build_dir = Path(tempfile.mkdtemp(prefix="k3v-gba-save-test-"))
    print(f"Using {simulator}; build directory: {build_dir}")

    try:
        command = (
            compile_iverilog(build_dir, iverilog, vvp)
            if simulator == "iverilog"
            else compile_verilator(build_dir, verilator)
        )

        transfer_args = [f"+SEED={args.seed}"]
        if args.full:
            transfer_args.append("+FULL")
        else:
            if args.bytes <= 0 or args.bytes > 128 * 1024 or args.bytes % 4:
                parser.error("--bytes must be a positive multiple of 4 up to 131072")
            transfer_args.append(f"+BYTES={args.bytes}")

        run([*command, *transfer_args])
        run([*command, "+STALL_ONLY", f"+SEED={args.seed}"])
    finally:
        if args.keep_build:
            print(f"Kept build directory: {build_dir}")
        else:
            shutil.rmtree(build_dir, ignore_errors=True)

    print("All save-path regressions passed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f"save-path test failure: {error}", file=sys.stderr)
        raise SystemExit(1)
