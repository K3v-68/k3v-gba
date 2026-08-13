#!/usr/bin/env python3
"""Report Quartus resource usage and enforce K3V's checked-in budget."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


SUMMARY_FIELDS = {
    "fitter_status": re.compile(r"^Fitter Status\s*:\s*(.+?)\s*$"),
    "quartus": re.compile(r"^Quartus Prime Version\s*:\s*(.+?)\s*$"),
    "device": re.compile(r"^Device\s*:\s*(\S+)\s*$"),
    "alms": re.compile(
        r"^Logic utilization \(in ALMs\)\s*:\s*([0-9,]+)\s*/\s*([0-9,]+)"
    ),
    "m10ks": re.compile(r"^Total RAM Blocks\s*:\s*([0-9,]+)\s*/\s*([0-9,]+)"),
    "block_memory_bits": re.compile(
        r"^Total block memory bits\s*:\s*([0-9,]+)\s*/\s*([0-9,]+)"
    ),
    "dsp_blocks": re.compile(
        r"^Total DSP Blocks\s*:\s*([0-9,]+)\s*/\s*([0-9,]+)"
    ),
}
QSF_FIELDS = {
    "device": re.compile(
        r"^\s*set_global_assignment\s+-name\s+DEVICE\s+(?:\"([^\"]+)\"|(\S+))\s*$"
    ),
    "seed": re.compile(
        r"^\s*set_global_assignment\s+-name\s+SEED\s+(?:\"([^\"]+)\"|(\S+))\s*$"
    ),
}


def parse_number(value: str) -> int:
    return int(value.replace(",", ""))


def unique_match(lines: list[str], pattern: re.Pattern[str], label: str) -> re.Match[str]:
    matches = [match for line in lines if (match := pattern.search(line.strip()))]
    if len(matches) != 1:
        raise ValueError(f"expected exactly one {label} field, found {len(matches)}")
    return matches[0]


def parse_fit_summary(path: Path) -> dict:
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    matches = {
        key: unique_match(lines, pattern, key)
        for key, pattern in SUMMARY_FIELDS.items()
    }
    fitter_status = matches["fitter_status"].group(1)
    if not fitter_status.startswith("Successful"):
        raise ValueError(f"Quartus fitter was not successful: {fitter_status}")
    usage = {}
    for key in ("alms", "m10ks", "block_memory_bits", "dsp_blocks"):
        used = parse_number(matches[key].group(1))
        total = parse_number(matches[key].group(2))
        if total <= 0:
            raise ValueError(f"{key} device total must be positive, found {total}")
        if used > total:
            raise ValueError(f"{key} usage {used} exceeds device total {total}")
        usage[key] = {"used": used, "total": total}
    return {
        "fitter_status": fitter_status,
        "quartus": matches["quartus"].group(1),
        "device": matches["device"].group(1),
        "usage": usage,
    }


def parse_qsf(path: Path) -> dict:
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    values = {}
    for key, pattern in QSF_FIELDS.items():
        match = unique_match(lines, pattern, f"QSF {key}")
        values[key] = match.group(1) or match.group(2)
    values["seed"] = int(values["seed"])
    return values


def load_budget(path: Path) -> dict:
    budget = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(budget, dict):
        raise ValueError(f"{path}: resource budget must be a JSON object")
    top_level_keys = {
        "schema",
        "reference",
        "reference_commit",
        "release_commit",
        "device",
        "quartus",
        "seed",
        "device_totals",
        "baseline",
        "limits",
        "targets",
        "tradeoffs",
    }
    if set(budget) != top_level_keys:
        raise ValueError(
            f"{path}: top-level keys must be {sorted(top_level_keys)}, "
            f"found {sorted(budget)}"
        )
    if type(budget.get("schema")) is not int or budget["schema"] != 1:
        raise ValueError(f"{path}: unsupported resource budget schema")

    for key in (
        "reference",
        "reference_commit",
        "release_commit",
        "device",
        "quartus",
    ):
        if not isinstance(budget.get(key), str) or not budget[key].strip():
            raise ValueError(f"{path}: {key} must be a non-empty string")
    if type(budget.get("seed")) is not int or budget["seed"] < 0:
        raise ValueError(f"{path}: seed must be a non-negative integer")

    for section in ("device_totals", "baseline", "limits", "targets"):
        if not isinstance(budget.get(section), dict):
            raise ValueError(f"{path}: missing {section} object")

    expected_keys = {
        "device_totals": {"alms", "m10ks"},
        "baseline": {"alms", "m10ks"},
        "limits": {"alms", "m10ks"},
        "targets": {"alms"},
    }
    for section, keys in expected_keys.items():
        actual_keys = set(budget[section])
        if actual_keys != keys:
            raise ValueError(
                f"{path}: {section} keys must be {sorted(keys)}, "
                f"found {sorted(actual_keys)}"
            )
        for key in keys:
            value = budget[section][key]
            if type(value) is not int or value < 0:
                raise ValueError(
                    f"{path}: {section}.{key} must be a non-negative integer"
                )

    for key in ("alms", "m10ks"):
        total = budget["device_totals"][key]
        if total <= 0:
            raise ValueError(f"{path}: device_totals.{key} must be positive")
        for section in ("baseline", "limits"):
            if budget[section][key] > total:
                raise ValueError(
                    f"{path}: {section}.{key} exceeds device_totals.{key}"
                )
    if budget["limits"]["alms"] > budget["baseline"]["alms"]:
        raise ValueError(f"{path}: limits.alms may not exceed baseline.alms")
    if budget["targets"]["alms"] > budget["limits"]["alms"]:
        raise ValueError(f"{path}: targets.alms may not exceed limits.alms")

    tradeoffs = budget.get("tradeoffs")
    if not isinstance(tradeoffs, dict):
        raise ValueError(f"{path}: missing tradeoffs object")
    maximum_added_m10ks = 0
    for name, tradeoff in tradeoffs.items():
        if not isinstance(name, str) or not name:
            raise ValueError(f"{path}: tradeoff names must be non-empty strings")
        if not isinstance(tradeoff, dict):
            raise ValueError(f"{path}: tradeoffs.{name} must be an object")
        keys = {"maximum_added_m10ks", "requires_alm_reduction", "reason"}
        if set(tradeoff) != keys:
            raise ValueError(
                f"{path}: tradeoffs.{name} keys must be {sorted(keys)}, "
                f"found {sorted(tradeoff)}"
            )
        added = tradeoff["maximum_added_m10ks"]
        if type(added) is not int or added < 0:
            raise ValueError(
                f"{path}: tradeoffs.{name}.maximum_added_m10ks must be "
                "a non-negative integer"
            )
        if type(tradeoff["requires_alm_reduction"]) is not bool:
            raise ValueError(
                f"{path}: tradeoffs.{name}.requires_alm_reduction must be a boolean"
            )
        if not isinstance(tradeoff["reason"], str) or not tradeoff["reason"].strip():
            raise ValueError(
                f"{path}: tradeoffs.{name}.reason must be a non-empty string"
            )
        maximum_added_m10ks += added

    allowed_m10ks = budget["baseline"]["m10ks"] + maximum_added_m10ks
    if allowed_m10ks > budget["device_totals"]["m10ks"]:
        raise ValueError(
            f"{path}: declared M10K tradeoffs exceed the device capacity"
        )
    if budget["limits"]["m10ks"] != allowed_m10ks:
        raise ValueError(
            f"{path}: limits.m10ks must equal the baseline plus declared tradeoffs"
        )
    return budget


def evaluate(build: dict, qsf: dict, budget: dict) -> list[str]:
    errors: list[str] = []
    if build["device"] != budget["device"]:
        errors.append(
            f"fitter device is {build['device']}, expected {budget['device']}"
        )
    if qsf["device"] != budget["device"]:
        errors.append(f"QSF device is {qsf['device']}, expected {budget['device']}")
    expected_quartus = budget["quartus"]
    if not (
        build["quartus"] == expected_quartus
        or build["quartus"].startswith(expected_quartus + " ")
    ):
        errors.append(
            f"Quartus version is {build['quartus']!r}, expected {budget['quartus']!r}"
        )
    if qsf["seed"] != int(budget["seed"]):
        errors.append(f"QSF seed is {qsf['seed']}, expected {int(budget['seed'])}")

    usage = build["usage"]
    for key in ("alms", "m10ks"):
        actual_total = usage[key]["total"]
        expected_total = int(budget["device_totals"][key])
        if actual_total != expected_total:
            errors.append(
                f"{key} device total is {actual_total}, expected {expected_total}"
            )
        used = usage[key]["used"]
        maximum = int(budget["limits"][key])
        if used > maximum:
            errors.append(f"{key} regressed to {used}; budget allows at most {maximum}")

    added_m10ks = max(0, usage["m10ks"]["used"] - budget["baseline"]["m10ks"])
    free_added_m10ks = sum(
        tradeoff["maximum_added_m10ks"]
        for tradeoff in budget["tradeoffs"].values()
        if not tradeoff["requires_alm_reduction"]
    )
    if (
        added_m10ks > free_added_m10ks
        and usage["alms"]["used"] >= budget["baseline"]["alms"]
    ):
        errors.append(
            "the declared M10K tradeoff requires ALM usage below the baseline "
            f"of {budget['baseline']['alms']}"
        )
    return errors


def build_result(build: dict, qsf: dict, budget: dict) -> dict:
    usage = build["usage"]
    result = {
        "schema": 1,
        "reference": budget["reference"],
        "reference_commit": budget["reference_commit"],
        "release_commit": budget["release_commit"],
        "environment": {
            "device": build["device"],
            "quartus": build["quartus"],
            "seed": qsf["seed"],
        },
        "usage": usage,
        "deltas_from_baseline": {
            "alms": usage["alms"]["used"] - int(budget["baseline"]["alms"]),
            "m10ks": usage["m10ks"]["used"] - int(budget["baseline"]["m10ks"]),
        },
        "limits": budget["limits"],
        "targets": budget["targets"],
        "target_status": {
            "alms_met": usage["alms"]["used"] <= int(budget["targets"]["alms"])
        },
    }
    result["errors"] = evaluate(build, qsf, budget)
    result["passed"] = not result["errors"]
    return result


def signed(value: int) -> str:
    return f"{value:+d}"


def markdown(result: dict) -> str:
    usage = result["usage"]
    deltas = result["deltas_from_baseline"]
    limits = result["limits"]
    target = int(result["targets"]["alms"])
    lines = [
        "## FPGA resource budget",
        "",
        f"Baseline: `{result['reference']}`. Raw counts are used instead of rounded percentages.",
        "",
        "| Resource | Used / total | Exact use | Baseline delta | Limit |",
        "|---|---:|---:|---:|---:|",
    ]
    for label, key in (("ALMs", "alms"), ("M10Ks", "m10ks")):
        item = usage[key]
        lines.append(
            f"| {label} | {item['used']:,} / {item['total']:,} | "
            f"{100 * item['used'] / item['total']:.2f}% | {signed(deltas[key])} | "
            f"{int(limits[key]):,} |"
        )
    for label, key in (("Memory bits", "block_memory_bits"), ("DSP blocks", "dsp_blocks")):
        item = usage[key]
        lines.append(
            f"| {label} | {item['used']:,} / {item['total']:,} | "
            f"{100 * item['used'] / item['total']:.2f}% | n/a | report only |"
        )
    lines.extend(
        [
            "",
            f"v0.2.0 ALM target: **{target:,}** "
            f"({'met' if result['target_status']['alms_met'] else 'not met'}).",
        ]
    )
    if result["errors"]:
        lines.extend(["", "### Budget failures", ""])
        lines.extend(f"- {error}" for error in result["errors"])
    else:
        lines.extend(["", "Resource budget passed."])
    return "\n".join(lines) + "\n"


def append_text(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8", newline="\n") as output:
        output.write(value)


def failure_result(error: Exception) -> dict:
    return {
        "schema": 1,
        "passed": False,
        "status": "invalid",
        "errors": [f"resource check failure: {error}"],
    }


def failure_markdown(result: dict) -> str:
    lines = [
        "## FPGA resource budget",
        "",
        "Resource check could not be completed.",
        "",
        "### Validation failures",
        "",
    ]
    lines.extend(f"- {error}" for error in result["errors"])
    return "\n".join(lines) + "\n"


def write_outputs(args: argparse.Namespace, result: dict, report: str) -> None:
    json_text = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json_text, encoding="utf-8", newline="\n")
    if args.markdown_out:
        args.markdown_out.parent.mkdir(parents=True, exist_ok=True)
        args.markdown_out.write_text(report, encoding="utf-8", newline="\n")
    if args.github_summary:
        append_text(args.github_summary, report)


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--summary", type=Path, required=True)
    parser.add_argument("--qsf", type=Path, required=True)
    parser.add_argument(
        "--budget",
        type=Path,
        default=root / "benchmarks/quartus-resource-budget.json",
    )
    parser.add_argument("--json-out", type=Path)
    parser.add_argument("--markdown-out", type=Path)
    parser.add_argument("--github-summary", type=Path)
    args = parser.parse_args()

    try:
        build = parse_fit_summary(args.summary)
        qsf = parse_qsf(args.qsf)
        result = build_result(build, qsf, load_budget(args.budget))
        report = markdown(result)
        print(report, end="")
        write_outputs(args, result, report)
        return 0 if result["passed"] else 1
    except (OSError, ValueError, TypeError, KeyError, ZeroDivisionError) as error:
        result = failure_result(error)
        report = failure_markdown(result)
        print(report, end="")
        print(f"resource check failure: {error}", file=sys.stderr)
        try:
            write_outputs(args, result, report)
        except OSError as output_error:
            print(
                f"resource check could not write failure evidence: {output_error}",
                file=sys.stderr,
            )
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
