#!/usr/bin/env python3
"""Run fail-closed external-SRAM save snapshot regressions."""

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
    os.environ["PATH"] = os.pathsep.join(
        [str(Path(iverilog).parent), str(Path(vvp).parent), os.environ.get("PATH", "")]
    )

    cases = (
        ("healthy", ()),
        (
            "sram-55ns-access",
            (
                "tb_save_snapshot.DUT_SRAM_WAIT_CYCLES=8",
                "tb_save_snapshot.SRAM_ACCESS_NS=55",
            ),
        ),
        (
            "delayed-source-acceptance",
            ("tb_save_snapshot.SOURCE_ACCEPT_DELAY=100",),
        ),
        (
            "delayed-response-release",
            ("tb_save_snapshot.RESPONSE_RELEASE_HOLD=20",),
        ),
        (
            "abort-during-copy",
            (
                "tb_save_snapshot.TEST_ABORT_DURING_COPY=1",
                "tb_save_snapshot.SOURCE_ABORT_DRAIN_DELAY=20",
            ),
        ),
        (
            "out-of-order-stream",
            ("tb_save_snapshot.TEST_OUT_OF_ORDER=1",),
        ),
        (
            "middle-duplicate-stream",
            ("tb_save_snapshot.TEST_MIDDLE_DUPLICATE=1",),
        ),
        (
            "missing-first-source-response",
            (
                "tb_save_snapshot.SUPPRESS_SOURCE_WORD=0",
                "tb_save_snapshot.EXPECT_FAILURE=1",
            ),
        ),
        (
            "missing-middle-source-response",
            (
                "tb_save_snapshot.SUPPRESS_SOURCE_WORD=7",
                "tb_save_snapshot.EXPECT_FAILURE=1",
            ),
        ),
        (
            "missing-last-source-response",
            (
                "tb_save_snapshot.SUPPRESS_SOURCE_WORD=15",
                "tb_save_snapshot.EXPECT_FAILURE=1",
            ),
        ),
        (
            "corrupt-last-sram-readback",
            (
                "tb_save_snapshot.CORRUPT_READBACK_WORD=15",
                "tb_save_snapshot.EXPECT_FAILURE=1",
            ),
        ),
    )

    build_dir = Path(tempfile.mkdtemp(prefix="k3v-gba-snapshot-test-"))
    try:
        for name, parameters in cases:
            output = build_dir / f"{name}.vvp"
            command = [iverilog, "-g2012", "-Wall", "-s", "tb_save_snapshot"]
            for parameter in parameters:
                command.extend(("-P", parameter))
            command.extend(
                (
                    "-o",
                    str(output),
                    str(REPO_ROOT / "src/fpga/pocket/save_snapshot.sv"),
                    str(TEST_DIR / "tb_save_snapshot.sv"),
                )
            )
            run(command)
            run([vvp, str(output)])
    finally:
        shutil.rmtree(build_dir, ignore_errors=True)

    print("Save snapshot fail-closed regressions passed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"snapshot test failure: {error}", file=sys.stderr)
        raise SystemExit(1)
