#!/usr/bin/env python3
"""Reject missing, zero-path, or negative-slack custom TimeQuest reports."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


SUMMARY_RE = re.compile(
    r"Report Timing:\s+Found\s+(?P<count>\d+)\s+paths?.*?"
    r"Worst case slack is\s+(?P<slack>[-+0-9.]+)",
    re.IGNORECASE,
)


def check_report(path: Path) -> tuple[int, float]:
    if not path.is_file() or path.stat().st_size == 0:
        raise RuntimeError(f"missing or empty STA path report: {path}")

    match = SUMMARY_RE.search(path.read_text(errors="replace"))
    if match is None:
        raise RuntimeError(f"STA path report has no parseable timing summary: {path}")

    count = int(match.group("count"))
    slack = float(match.group("slack"))
    if count <= 0:
        raise RuntimeError(f"STA path report contains zero paths: {path}")
    if slack < 0.0:
        raise RuntimeError(f"STA path report has negative slack {slack:.3f} ns: {path}")
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
