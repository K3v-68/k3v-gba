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


def run_net_delay_report(
    *slacks: float,
    extra_row: str | None = None,
    extra_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
    rows = [
        f"; set_net_delay ; {slack:.3f} ; 9.931 ; 6.167 ; from ; to ; max ;"
        for slack in slacks
    ]
    if extra_row is not None:
        rows.append(extra_row)
    if extra_text is not None:
        rows.append(extra_text)
    with tempfile.NamedTemporaryFile(
        "w", prefix="ap_core.sta.snapshot_cdc_net_delay.", suffix=".rpt"
    ) as fixture:
        fixture.write("\n".join(rows) + "\n")
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
    branch_workflow = (
        REPO_ROOT / ".github" / "workflows" / "build-branch.yml"
    ).read_text(encoding="utf-8")
    release_workflow = (
        REPO_ROOT / ".github" / "workflows" / "build.yml"
    ).read_text(encoding="utf-8")
    required_reports = (
        "ap_core.sta.sram_output_setup.rpt",
        "ap_core.sta.sram_input_setup.rpt",
        "ap_core.sta.sram_output_hold.rpt",
        "ap_core.sta.sram_input_hold.rpt",
        "ap_core.sta.snapshot_cdc_net_delay.rpt",
        "scripts/check_sta_path_reports.py",
    )
    for workflow_name, workflow in (
        ("branch", branch_workflow),
        ("release", release_workflow),
    ):
        for required in required_reports:
            if required not in workflow:
                raise RuntimeError(
                    f"{workflow_name} CI timing contract missing {required}"
                )
    if "--allow-experimental-branch" not in branch_workflow:
        raise RuntimeError("branch CI resource contract missing experimental allowance")
    if "--allow-experimental-branch" in release_workflow:
        raise RuntimeError("release CI must retain the strict resource budget")

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
        "Report Timing: Found 40 setup paths (0 violated). Worst case slack is 1.821"
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

    net_delay_positive = run_net_delay_report(3.764, 4.702)
    if net_delay_positive.returncode != 0:
        raise RuntimeError(
            f"valid CDC net-delay report was rejected:\n{net_delay_positive.stdout}"
        )
    net_delay_empty = run_net_delay_report()
    if net_delay_empty.returncode == 0 or "no parseable" not in net_delay_empty.stdout:
        raise RuntimeError(
            f"empty CDC net-delay report was not rejected:\n{net_delay_empty.stdout}"
        )
    net_delay_missing_row = run_net_delay_report(3.764)
    if (
        net_delay_missing_row.returncode == 0
        or "expected 2" not in net_delay_missing_row.stdout
    ):
        raise RuntimeError(
            "incomplete CDC net-delay report was not rejected:\n"
            f"{net_delay_missing_row.stdout}"
        )
    net_delay_zero = run_net_delay_report(3.764, 0.0)
    if net_delay_zero.returncode == 0 or "non-positive slack" not in net_delay_zero.stdout:
        raise RuntimeError(
            f"zero CDC net-delay slack was not rejected:\n{net_delay_zero.stdout}"
        )
    net_delay_malformed_extra = run_net_delay_report(
        3.764,
        4.702,
        extra_row="; set_net_delay ; N/A ; N/A ; N/A ; from ; to ; max ;",
    )
    if (
        net_delay_malformed_extra.returncode == 0
        or "expected 2" not in net_delay_malformed_extra.stdout
    ):
        raise RuntimeError(
            "extra malformed CDC net-delay row was not rejected:\n"
            f"{net_delay_malformed_extra.stdout}"
        )
    generic_summary = (
        "Report Timing: Found 1 path. Worst case slack is 1.000"
    )
    net_delay_mixed_missing = run_net_delay_report(
        3.764, extra_text=generic_summary
    )
    if (
        net_delay_mixed_missing.returncode == 0
        or "expected 2" not in net_delay_mixed_missing.stdout
    ):
        raise RuntimeError(
            "generic summary bypassed missing CDC row rejection:\n"
            f"{net_delay_mixed_missing.stdout}"
        )
    net_delay_mixed_malformed = run_net_delay_report(
        3.764,
        4.702,
        extra_row="; set_net_delay ; N/A ; N/A ; N/A ; from ; to ; max ;",
        extra_text=generic_summary,
    )
    if (
        net_delay_mixed_malformed.returncode == 0
        or "expected 2" not in net_delay_mixed_malformed.stdout
    ):
        raise RuntimeError(
            "generic summary bypassed malformed CDC row rejection:\n"
            f"{net_delay_mixed_malformed.stdout}"
        )
    net_delay_negative = run_net_delay_report(3.764, -0.125)
    if net_delay_negative.returncode == 0 or "negative slack" not in net_delay_negative.stdout:
        raise RuntimeError(
            "negative CDC net-delay slack was not rejected:\n"
            f"{net_delay_negative.stdout}"
        )

    print(
        "TIMING RELEASE GATE PASS positive=accepted negative_setup=rejected "
        "negative_hold=rejected zero_path=rejected custom_negative=rejected"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
