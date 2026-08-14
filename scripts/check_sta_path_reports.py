#!/usr/bin/env python3
"""Reject missing, zero-path, or negative-slack custom TimeQuest reports."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


SUMMARY_RE = re.compile(
    r"Report Timing:\s+Found\s+(?P<count>\d+)\s+"
    r"(?:(?:setup|hold)\s+)?paths?.*?"
    r"Worst case slack is\s+(?P<slack>[-+0-9.]+)",
    re.IGNORECASE,
)
NET_DELAY_ROW_RE = re.compile(
    r"^\s*;\s*set_net_delay\s*;(?P<body>.*)$",
    re.IGNORECASE | re.MULTILINE,
)
NET_DELAY_SLACK_RE = re.compile(r"^\s*(?P<slack>[-+0-9.]+)\s*;")


def check_report(path: Path) -> tuple[int, float]:
    if not path.is_file() or path.stat().st_size == 0:
        raise RuntimeError(f"missing or empty STA path report: {path}")

    report = path.read_text(errors="replace")
    is_net_delay = "snapshot_cdc_net_delay" in path.name
    if is_net_delay:
        net_delay_rows = list(NET_DELAY_ROW_RE.finditer(report))
        if not net_delay_rows:
            raise RuntimeError(
                f"STA path report has no parseable timing summary: {path}"
            )
        if len(net_delay_rows) != 2:
            raise RuntimeError(
                "snapshot CDC net-delay report expected 2 constraint rows, "
                f"found {len(net_delay_rows)}: {path}"
            )
        net_delay_slacks = []
        for row in net_delay_rows:
            slack_match = NET_DELAY_SLACK_RE.match(row.group("body"))
            if slack_match is None:
                raise RuntimeError(
                    f"snapshot CDC net-delay report has malformed slack: {path}"
                )
            net_delay_slacks.append(float(slack_match.group("slack")))
        count = len(net_delay_slacks)
        slack = min(net_delay_slacks)
    else:
        match = SUMMARY_RE.search(report)
        if match is None:
            raise RuntimeError(
                f"STA path report has no parseable timing summary: {path}"
            )
        count = int(match.group("count"))
        slack = float(match.group("slack"))
    if count <= 0:
        raise RuntimeError(f"STA path report contains zero paths: {path}")
    if slack < 0.0:
        raise RuntimeError(f"STA path report has negative slack {slack:.3f} ns: {path}")
    if is_net_delay and slack == 0.0:
        raise RuntimeError(
            f"snapshot CDC net-delay report has non-positive slack {slack:.3f} ns: {path}"
        )
    return count, slack


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("reports", nargs="+", type=Path)
    args = parser.parse_args()

    for report in args.reports:
        count, slack = check_report(report)
        print(f"STA PATH REPORT PASS {report.name} paths={count} worst_slack={slack:+.3f}ns")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print(f"STA PATH REPORT FAIL: {error}")
        raise SystemExit(1)
