#!/usr/bin/env python3
"""Prove release timing gate rejects negative setup or hold slack."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


TEST_DIR = Path(__file__).resolve().parent
REPO_ROOT = TEST_DIR.parents[1]
SCRIPT = REPO_ROOT / "scripts" / "print_timing.sh"
PATH_REPORT_SCRIPT = REPO_ROOT / "scripts" / "check_sta_path_reports.py"


def summary(setup: float, hold: float) -> str:
    return f"""Type  : Slow 1100mV 85C Model Setup 'clk_74a'
Slack : {setup:.3f}
TNS   : {min(setup, 0.0):.3f}

Type  : Slow 1100mV 85C Model Hold 'clk_74a'
Slack : {hold:.3f}
TNS   : {min(hold, 0.0):.3f}
"""


def run_case(setup: float, hold: float) -> subprocess.CompletedProcess[str]:
    with tempfile.NamedTemporaryFile("w", suffix=".sta.summary") as fixture:
        fixture.write(summary(setup, hold))
        fixture.flush()
        return subprocess.run(
            [str(SCRIPT), fixture.name],
            cwd=REPO_ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )


def run_path_report(summary_line: str) -> subprocess.CompletedProcess[str]:
    with tempfile.NamedTemporaryFile("w", suffix=".sta.rpt") as fixture:
        fixture.write(summary_line + "\n")
        fixture.flush()
        return subprocess.run(
            [str(PATH_REPORT_SCRIPT), fixture.name],
            cwd=REPO_ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )


def main() -> int:
    positive = run_case(0.250, 0.125)
    if positive.returncode != 0 or "Timing met." not in positive.stdout:
        raise RuntimeError(f"positive timing case failed:\n{positive.stdout}")

    setup_failure = run_case(-0.050, 0.125)
    if setup_failure.returncode == 0 or "Negative setup slack" not in setup_failure.stdout:
        raise RuntimeError(f"negative setup was not rejected:\n{setup_failure.stdout}")

    hold_failure = run_case(0.250, -0.050)
    if hold_failure.returncode == 0 or "Negative hold slack" not in hold_failure.stdout:
        raise RuntimeError(f"negative hold was not rejected:\n{hold_failure.stdout}")

    path_positive = run_path_report(
        "Report Timing: Found 16 paths. Worst case slack is 0.125"
    )
    if path_positive.returncode != 0:
        raise RuntimeError(f"valid custom path report was rejected:\n{path_positive.stdout}")

    path_zero = run_path_report(
        "Report Timing: Found 0 paths. Worst case slack is 0.000"
    )
    if path_zero.returncode == 0 or "zero paths" not in path_zero.stdout:
        raise RuntimeError(f"zero-path custom report was not rejected:\n{path_zero.stdout}")

    path_negative = run_path_report(
        "Report Timing: Found 16 paths. Worst case slack is -0.125"
    )
    if path_negative.returncode == 0 or "negative slack" not in path_negative.stdout:
        raise RuntimeError(
            f"negative custom report slack was not rejected:\n{path_negative.stdout}"
        )

    print(
        "TIMING RELEASE GATE PASS positive=accepted negative_setup=rejected "
        "negative_hold=rejected zero_path=rejected custom_negative=rejected"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
