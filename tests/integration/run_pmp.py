#!/usr/bin/env python3
"""Exercise save export through the production physical PMP bridge pipeline."""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


TEST_DIR = Path(__file__).resolve().parent
REPO_ROOT = TEST_DIR.parents[1]


def resolve_tool(explicit: str | None, name: str) -> str:
    candidate = explicit or shutil.which(name)
    if not candidate:
        raise RuntimeError(f"{name} was not found; pass --{name} explicitly")
    path = Path(candidate).resolve()
    if not path.is_file():
        raise RuntimeError(f"{name} executable does not exist: {candidate}")
    return str(path)


def configure_portable_runtime(*tools: str) -> None:
    paths: list[str] = []
    for tool in tools:
        binary_dir = Path(tool).parent
        paths.append(str(binary_dir))
        library_dir = binary_dir.parent / "lib"
        if library_dir.is_dir():
            paths.append(str(library_dir))
    os.environ["PATH"] = os.pathsep.join(
        [*dict.fromkeys(paths), os.environ.get("PATH", "")]
    )


def compile_case(
    compiler: str,
    build_dir: Path,
    name: str,
    fifo_model: Path,
    parameters: tuple[str, ...],
) -> Path:
    output = build_dir / f"{name}.vvp"
    command = [compiler, "-g2012", "-Wall", "-s", "tb_pmp_save_export"]
    for parameter in parameters:
        command.extend(("-P", parameter))
    command.extend(
        (
            "-o",
            str(output),
            str(REPO_ROOT / "src" / "fpga" / "apf" / "common.v"),
            str(REPO_ROOT / "src" / "fpga" / "apf" / "io_bridge_peripheral.v"),
            str(fifo_model),
            str(REPO_ROOT / "src" / "fpga" / "pocket" / "data_unloader.sv"),
            str(REPO_ROOT / "src" / "fpga" / "pocket" / "save_snapshot.sv"),
            str(REPO_ROOT / "src" / "fpga" / "pocket" / "psram.sv"),
            str(TEST_DIR / "tb_pmp_save_export.sv"),
        )
    )
    print("+", " ".join(command), flush=True)
    subprocess.run(command, cwd=REPO_ROOT, check=True)
    return output


def run_case(runtime: str, image: Path) -> None:
    command = [runtime, str(image)]
    print("+", " ".join(command), flush=True)
    subprocess.run(command, cwd=REPO_ROOT, check=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iverilog", help="explicit Icarus Verilog executable")
    parser.add_argument("--vvp", help="explicit Icarus runtime executable")
    parser.add_argument(
        "--bytes",
        type=int,
        default=131072,
        help="healthy patterned cart-save fixture size (default: 131072)",
    )
    parser.add_argument(
        "--vendor-model",
        type=Path,
        help="optional Quartus altera_mf.v path instead of the behavioral dcfifo",
    )
    parser.add_argument(
        "--full-starvation",
        action="store_true",
        help="run starvation for --bytes bytes; sizes above 4 require the vendor model",
    )
    parser.add_argument("--keep-build", action="store_true")
    args = parser.parse_args()

    if args.bytes <= 0 or args.bytes % 4:
        parser.error("--bytes must be a positive multiple of four")
    if args.full_starvation and args.bytes > 4 and not args.vendor_model:
        parser.error(
            "--full-starvation above 4 bytes requires --vendor-model because "
            "the behavioral FIFO deliberately fatals on overflow"
        )

    compiler = resolve_tool(args.iverilog, "iverilog")
    runtime = resolve_tool(args.vvp, "vvp")
    configure_portable_runtime(compiler, runtime)
    fifo_model = (
        args.vendor_model.resolve()
        if args.vendor_model
        else REPO_ROOT / "tests" / "save" / "dcfifo_model.sv"
    )
    if not fifo_model.is_file():
        parser.error(f"FIFO model does not exist: {fifo_model}")

    starvation_bytes = args.bytes if args.full_starvation else 4
    build_dir = Path(tempfile.mkdtemp(prefix="k3v-gba-pmp-export-test-"))
    print(f"Build directory: {build_dir}")
    try:
        healthy = compile_case(
            compiler,
            build_dir,
            "pmp_healthy",
            fifo_model,
            (f"tb_pmp_save_export.BODY_BYTES={args.bytes}",),
        )
        starved = compile_case(
            compiler,
            build_dir,
            "pmp_starved",
            fifo_model,
            (
                f"tb_pmp_save_export.BODY_BYTES={starvation_bytes}",
                "tb_pmp_save_export.RUN_RTC=0",
                "tb_pmp_save_export.SUPPRESS_CART_RESPONSE=1",
                "tb_pmp_save_export.EXPECT_ALL_ZERO=1",
            ),
        )
        snapshot = compile_case(
            compiler,
            build_dir,
            "pmp_snapshot",
            fifo_model,
            (
                f"tb_pmp_save_export.BODY_BYTES={args.bytes}",
                "tb_pmp_save_export.RUN_RTC=0",
                "tb_pmp_save_export.USE_SNAPSHOT=1",
            ),
        )
        duplicate = compile_case(
            compiler,
            build_dir,
            "pmp_snapshot_middle_duplicate",
            fifo_model,
            (
                "tb_pmp_save_export.BODY_BYTES=64",
                "tb_pmp_save_export.RUN_RTC=0",
                "tb_pmp_save_export.USE_SNAPSHOT=1",
                "tb_pmp_save_export.INJECT_MIDDLE_DUPLICATE=1",
            ),
        )
        boundary_duplicate = compile_case(
            compiler,
            build_dir,
            "pmp_snapshot_1k_boundary_prime",
            fifo_model,
            (
                f"tb_pmp_save_export.BODY_BYTES={args.bytes}",
                "tb_pmp_save_export.RUN_RTC=0",
                "tb_pmp_save_export.USE_SNAPSHOT=1",
                "tb_pmp_save_export.INJECT_BOUNDARY_PRIME_DUPLICATE=1",
            ),
        )
        with ThreadPoolExecutor(max_workers=5) as executor:
            healthy_result = executor.submit(run_case, runtime, healthy)
            starved_result = executor.submit(run_case, runtime, starved)
            snapshot_result = executor.submit(run_case, runtime, snapshot)
            duplicate_result = executor.submit(run_case, runtime, duplicate)
            boundary_duplicate_result = executor.submit(
                run_case, runtime, boundary_duplicate
            )
            healthy_result.result()
            starved_result.result()
            snapshot_result.result()
            duplicate_result.result()
            boundary_duplicate_result.result()
    finally:
        if args.keep_build:
            print(f"Kept build directory: {build_dir}")
        else:
            shutil.rmtree(build_dir, ignore_errors=True)

    print("Physical PMP save-export characterization passed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"physical PMP save-export test failure: {error}", file=sys.stderr)
        raise SystemExit(1)
