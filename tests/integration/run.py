#!/usr/bin/env python3
"""Run full save-ingress and fixed-cadence save-export integration tests."""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


TEST_DIR = Path(__file__).resolve().parent
REPO_ROOT = TEST_DIR.parents[1]
FIFO_MODEL = REPO_ROOT / "tests" / "save" / "dcfifo_model.sv"
DATA_UNLOADER = REPO_ROOT / "src" / "fpga" / "pocket" / "data_unloader.sv"


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


def require_logic_unloader_fifos() -> None:
    source = DATA_UNLOADER.read_text(encoding="utf-8")
    assignments = re.findall(
        r"\b([A-Za-z_][A-Za-z0-9_]*)\.use_eab\s*=\s*\"([^\"]+)\"",
        source,
    )
    expected = Counter(
        {
            ("fifo_address_req", "OFF"): 1,
            ("fifo_data_response", "OFF"): 1,
        }
    )
    if Counter(assignments) != expected:
        rendered = ", ".join(f"{instance}={value}" for instance, value in assignments)
        raise RuntimeError(
            "save-export regression requires exactly two logic-mapped unloader "
            'FIFOs: fifo_address_req.use_eab="OFF" and '
            'fifo_data_response.use_eab="OFF"; found '
            f"{rendered or 'none'}"
        )


def run(command: list[str]) -> None:
    print("+", " ".join(command), flush=True)
    subprocess.run(command, cwd=REPO_ROOT, check=True)


def run_expect_deadline_detection(command: list[str], label: str) -> None:
    print("+", " ".join(command), f"# expect {label} deadline detection", flush=True)
    result = subprocess.run(
        command,
        cwd=REPO_ROOT,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    print(result.stdout, end="", flush=True)
    sentinel = "was not valid after 88 clocks"
    if result.returncode == 0 or sentinel not in result.stdout:
        raise RuntimeError(
            f"{label} response did not trigger the testbench deadline detector"
        )
    print(f"PASS: testbench detected the {label} response deadline miss.")


def compile_test(
    compiler: str,
    runtime: str,
    build_dir: Path,
    artifact: str,
    top: str,
    sources: list[Path],
    parameters: tuple[str, ...] = (),
) -> list[str]:
    output = build_dir / f"{artifact}.vvp"
    command = [compiler, "-g2012", "-Wall", "-s", top]
    for parameter in parameters:
        command.extend(("-P", parameter))
    command.extend(("-o", str(output)))
    command.extend(str(source) for source in sources)
    run(command)
    return [runtime, str(output)]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iverilog", help="explicit Icarus Verilog executable")
    parser.add_argument("--vvp", help="explicit Icarus runtime executable")
    parser.add_argument(
        "--keep-build",
        action="store_true",
        help="keep the temporary simulator build directory",
    )
    args = parser.parse_args()

    compiler = resolve_tool(args.iverilog, "iverilog")
    runtime = resolve_tool(args.vvp, "vvp")
    configure_portable_runtime(compiler, runtime)
    require_logic_unloader_fifos()

    build_dir = Path(tempfile.mkdtemp(prefix="k3v-gba-integration-test-"))
    print(f"Build directory: {build_dir}")
    try:
        import_command = compile_test(
            compiler,
            runtime,
            build_dir,
            "save_ingress_full",
            "tb_save_ingress_psram",
            [
                FIFO_MODEL,
                REPO_ROOT / "src" / "fpga" / "pocket" / "apf_write_ingress.sv",
                REPO_ROOT / "src" / "fpga" / "pocket" / "psram.sv",
                TEST_DIR / "tb_save_ingress_psram.sv",
            ],
            ("tb_save_ingress_psram.SAVE_HALFWORDS=65536",),
        )
        export_ff_command = compile_test(
            compiler,
            runtime,
            build_dir,
            "save_export_ff_full",
            "tb_clear_unload_pipeline",
            [
                FIFO_MODEL,
                DATA_UNLOADER,
                REPO_ROOT / "src" / "fpga" / "pocket" / "psram.sv",
                TEST_DIR / "tb_clear_unload_pipeline.sv",
            ],
            (
                "tb_clear_unload_pipeline.BODY_BYTES=131072",
                "tb_clear_unload_pipeline.FIXED_CADENCE=1",
                "tb_clear_unload_pipeline.CADENCE_CYCLES=88",
            ),
        )
        export_pattern_command = compile_test(
            compiler,
            runtime,
            build_dir,
            "save_export_pattern_full",
            "tb_clear_unload_pipeline",
            [
                FIFO_MODEL,
                DATA_UNLOADER,
                REPO_ROOT / "src" / "fpga" / "pocket" / "psram.sv",
                TEST_DIR / "tb_clear_unload_pipeline.sv",
            ],
            (
                "tb_clear_unload_pipeline.BODY_BYTES=131072",
                "tb_clear_unload_pipeline.FIXED_CADENCE=1",
                "tb_clear_unload_pipeline.CADENCE_CYCLES=88",
                "tb_clear_unload_pipeline.PATTERNED=1",
            ),
        )
        missing_command = compile_test(
            compiler,
            runtime,
            build_dir,
            "save_export_missing",
            "tb_clear_unload_pipeline",
            [
                FIFO_MODEL,
                DATA_UNLOADER,
                REPO_ROOT / "src" / "fpga" / "pocket" / "psram.sv",
                TEST_DIR / "tb_clear_unload_pipeline.sv",
            ],
            (
                "tb_clear_unload_pipeline.BODY_BYTES=4",
                "tb_clear_unload_pipeline.FIXED_CADENCE=1",
                "tb_clear_unload_pipeline.CADENCE_CYCLES=88",
                "tb_clear_unload_pipeline.SUPPRESS_RESPONSE=1",
            ),
        )
        delayed_command = compile_test(
            compiler,
            runtime,
            build_dir,
            "save_export_delayed",
            "tb_clear_unload_pipeline",
            [
                FIFO_MODEL,
                DATA_UNLOADER,
                REPO_ROOT / "src" / "fpga" / "pocket" / "psram.sv",
                TEST_DIR / "tb_clear_unload_pipeline.sv",
            ],
            (
                "tb_clear_unload_pipeline.BODY_BYTES=4",
                "tb_clear_unload_pipeline.FIXED_CADENCE=1",
                "tb_clear_unload_pipeline.CADENCE_CYCLES=88",
                "tb_clear_unload_pipeline.RESPONSE_DELAY_CYCLES=100",
            ),
        )
        # These full-size simulations are independent, so run them together
        # and pay for one 128 KiB transfer in CI wall time rather than three.
        with ThreadPoolExecutor(max_workers=3) as executor:
            import_result = executor.submit(run, import_command)
            export_ff_result = executor.submit(run, export_ff_command)
            export_pattern_result = executor.submit(run, export_pattern_command)
            import_result.result()
            export_ff_result.result()
            export_pattern_result.result()
        run_expect_deadline_detection(missing_command, "missing")
        run_expect_deadline_detection(delayed_command, "late")
    finally:
        if args.keep_build:
            print(f"Kept build directory: {build_dir}")
        else:
            shutil.rmtree(build_dir, ignore_errors=True)

    print("Full save ingress/export integration regressions passed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"save integration test failure: {error}", file=sys.stderr)
        raise SystemExit(1)
