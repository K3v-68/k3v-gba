#!/usr/bin/env python3
"""Run the full two-launch save-corruption lifecycle reproduction."""

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
SOURCES = (
    TEST_DIR / "dcfifo_model.sv",
    REPO_ROOT / "src" / "fpga" / "pocket" / "apf_write_ingress.sv",
    REPO_ROOT / "src" / "fpga" / "pocket" / "data_unloader.sv",
    REPO_ROOT / "tests" / "bridge" / "mf_datatable_model.sv",
    REPO_ROOT / "src" / "fpga" / "apf" / "common.v",
    REPO_ROOT / "src" / "fpga" / "core" / "core_bridge_cmd.v",
    TEST_DIR / "tb_failed_save_shutdown.sv",
)


def require_pattern(source: str, pattern: str, description: str) -> None:
    if not re.search(pattern, source, flags=re.MULTILINE | re.DOTALL):
        raise RuntimeError(f"production request-read contract missing: {description}")


def verify_production_contract() -> None:
    command_source = (
        REPO_ROOT / "src" / "fpga" / "core" / "core_bridge_cmd.v"
    ).read_text(encoding="utf-8")
    top_source = (
        REPO_ROOT / "src" / "fpga" / "core" / "core_top.sv"
    ).read_text(encoding="utf-8")
    unloader_source = (
        REPO_ROOT / "src" / "fpga" / "pocket" / "data_unloader.sv"
    ).read_text(encoding="utf-8")

    require_pattern(
        command_source,
        r"input\s+wire\s+\[1:0\]\s+dataslot_requestread_result",
        "explicit two-bit core_bridge_cmd result input",
    )
    require_pattern(
        command_source,
        r"host_resultcode\s*<=\s*\{14'd0,\s*dataslot_requestread_result\}",
        "0/1/2 result propagation to the APF host response",
    )
    if "dataslot_requestread_ok" in command_source or "dataslot_requestread_ok" in top_source:
        raise RuntimeError("obsolete boolean request-read result remains in production")

    require_pattern(
        top_source,
        r"dataslot_requestread_ack\s*=\s*dataslot_requestread\s*;",
        "one-cycle deferred ACK from the registered request level",
    )
    quiescence_match = re.search(
        r"wire\s+save_export_quiescent_sys\s*=\s*(.*?);",
        top_source,
        flags=re.MULTILINE | re.DOTALL,
    )
    if not quiescence_match:
        raise RuntimeError("production export-quiescence expression is missing")
    quiescence = quiescence_match.group(1)
    for required in (
        "!reset_n_s",
        "save_load_finalized",
        "!save_loader_busy",
        "!save_loader_grant",
        "!psram_busy",
        "!save_unload_pending",
        "clear_client_idle",
        "bus_client_idle",
    ):
        if required not in quiescence:
            raise RuntimeError(
                f"production export quiescence is missing {required}"
            )
    if "save_loader_settled" in quiescence or "dataslot_allcomplete" in quiescence:
        raise RuntimeError(
            "finalized export must not depend on the boot-only allcomplete drain barrier"
        )
    require_pattern(
        top_source,
        r"16'd10\s*:\s*begin.*?cart_export_failed_s.*?2'd1.*?"
        r"cart_export_ready_s.*?2'd0.*?2'd2",
        "slot-10 terminal/ready/pending classification with failure priority",
    )
    require_pattern(
        top_source,
        r"16'd11\s*:\s*dataslot_requestread_result\s*=\s*"
        r"rtc_export_ready_s\s*\?\s*2'd0\s*:\s*2'd2",
        "slot-11 RTC result independent of cart status",
    )
    require_pattern(
        top_source,
        r"save_unload_is_cart\s*&&\s*cart_export_ready_sys.*?"
        r"save_unload_is_rtc\s*&&\s*rtc_export_ready_sys",
        "address-selected cart/RTC unloader readiness",
    )
    if len(re.findall(r"\.use_eab\s*=\s*\"OFF\"", unloader_source)) != 2:
        raise RuntimeError(
            "both field-proven unload CDC queues must remain in logic"
        )


def find_tool(explicit: str | None, name: str) -> str:
    tool = explicit or shutil.which(name)
    if not tool:
        raise RuntimeError(f"{name} was not found; pass --{name}")
    path = Path(tool).resolve()
    if not path.is_file():
        raise RuntimeError(f"{name} does not exist: {path}")
    return str(path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iverilog", help="explicit Icarus compiler")
    parser.add_argument("--vvp", help="explicit Icarus runtime")
    parser.add_argument(
        "--characterize-unsafe",
        action="store_true",
        help="bypass the fail-safe to reproduce the historical zero overwrite",
    )
    parser.add_argument("--keep-build", action="store_true")
    args = parser.parse_args()

    verify_production_contract()

    compiler = find_tool(args.iverilog, "iverilog")
    runtime = find_tool(args.vvp, "vvp")
    binary_dirs = [str(Path(compiler).parent), str(Path(runtime).parent)]
    for tool in (compiler, runtime):
        library_dir = Path(tool).parent.parent / "lib"
        if library_dir.is_dir():
            binary_dirs.append(str(library_dir))
    os.environ["PATH"] = os.pathsep.join(
        [*dict.fromkeys(binary_dirs), os.environ.get("PATH", "")]
    )

    build_dir = Path(tempfile.mkdtemp(prefix="k3v-save-lifecycle-"))
    contract_output = build_dir / "requestread_contract.vvp"
    contract_compile = [
        compiler,
        "-g2012",
        "-Wall",
        "-s",
        "tb_dataslot_read_contract",
        "-o",
        str(contract_output),
        *(str(source) for source in SOURCES),
    ]
    output = build_dir / "failed_save_shutdown.vvp"
    reproduction_compile = [
        compiler,
        "-g2012",
        "-Wall",
        "-s",
        "tb_failed_save_shutdown",
    ]
    print("core_top request-read contract: explicit result with deferred ACK")
    reproduction_compile.extend(
        ["-o", str(output), *(str(source) for source in SOURCES)]
    )

    try:
        print("+", " ".join(contract_compile), flush=True)
        subprocess.run(contract_compile, cwd=REPO_ROOT, check=True)
        print("+", runtime, contract_output, flush=True)
        subprocess.run([runtime, str(contract_output)], cwd=REPO_ROOT, check=True)

        print("+", " ".join(reproduction_compile), flush=True)
        subprocess.run(reproduction_compile, cwd=REPO_ROOT, check=True)
        simulation_command = [runtime, str(output)]
        if args.characterize_unsafe:
            simulation_command.append("+CHARACTERIZE_UNSAFE")
        print("+", " ".join(simulation_command), flush=True)
        completed = subprocess.run(
            simulation_command,
            cwd=REPO_ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        print(completed.stdout, end="")

        if args.characterize_unsafe:
            marker = "CHARACTERIZED_UNSAFE_FAILURE"
            if completed.returncode or marker not in completed.stdout:
                raise RuntimeError(
                    "current-failure characterization did not complete as expected"
                )
            print("Historical unsafe failure reproduced deterministically.")
            return 0
        return completed.returncode
    finally:
        if args.keep_build:
            print(f"Kept build directory: {build_dir}")
        else:
            shutil.rmtree(build_dir, ignore_errors=True)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(f"save-lifecycle reproduction failure: {error}", file=sys.stderr)
        raise SystemExit(1)
