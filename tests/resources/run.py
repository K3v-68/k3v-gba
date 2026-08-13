#!/usr/bin/env python3
"""Self-check the Quartus resource parser and budget gate."""

from __future__ import annotations

import copy
import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/check_quartus_resources.py"


def load_checker():
    spec = importlib.util.spec_from_file_location("check_quartus_resources", SCRIPT)
    if spec is None or spec.loader is None:
        raise AssertionError(f"cannot import {SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def summary_text(
    *,
    alms: int = 17_655,
    m10ks: int = 278,
    device: str = "5CEBA4F23C8",
    quartus: str = "21.1.1 Build 850 06/23/2022 SJ Lite Edition",
    fitter_status: str = "Successful - Thu Aug 13 12:00:00 2026",
) -> str:
    return "\n".join(
        (
            f"Fitter Status : {fitter_status}",
            f"Quartus Prime Version : {quartus}",
            f"Device : {device}",
            f"Logic utilization (in ALMs) : {alms:,} / 18,480 ( 96 % )",
            "Total block memory bits : 2,056,488 / 3,153,920 ( 65 % )",
            f"Total RAM Blocks : {m10ks:,} / 308 ( 90 % )",
            "Total DSP Blocks : 26 / 66 ( 39 % )",
        )
    ) + "\n"


def budget_data() -> dict:
    return {
        "schema": 1,
        "reference": "K3V v0.1.4 release build 31662908925",
        "reference_commit": "7a9dfdfdbf864bc198d073f5b44698885007b3ae",
        "release_commit": "2892d34bb3db94c4a4ae493f48e2180e10f0983a",
        "device": "5CEBA4F23C8",
        "quartus": "21.1.1 Build 850",
        "seed": 9,
        "device_totals": {"alms": 18_480, "m10ks": 308},
        "baseline": {"alms": 17_655, "m10ks": 278},
        "limits": {"alms": 17_655, "m10ks": 286},
        "targets": {"alms": 17_000},
        "tradeoffs": {
            "embedded_cdc_fifos": {
                "maximum_added_m10ks": 8,
                "reason": "Test fixture for the checked-in ALM-to-M10K trade.",
            }
        },
    }


def assert_raises_value_error(action, fragment: str) -> None:
    try:
        action()
    except ValueError as error:
        assert fragment in str(error), (fragment, str(error))
    else:
        raise AssertionError(f"expected ValueError containing {fragment!r}")


def main() -> int:
    checker = load_checker()
    with tempfile.TemporaryDirectory(prefix="k3v-resource-test-") as directory:
        temp = Path(directory)
        summary = temp / "ap_core.fit.summary"
        qsf = temp / "ap_core.qsf"
        budget_path = temp / "resource-budget.json"
        json_out = temp / "resource-usage.json"
        markdown_out = temp / "resource-usage.md"

        summary.write_text(summary_text(), encoding="utf-8", newline="\n")
        qsf.write_text(
            "set_global_assignment -name DEVICE 5CEBA4F23C8\n"
            "set_global_assignment -name SEED 9\n",
            encoding="utf-8",
            newline="\n",
        )
        budget = budget_data()
        budget_path.write_text(
            json.dumps(budget, indent=2) + "\n", encoding="utf-8", newline="\n"
        )

        build = checker.parse_fit_summary(summary)
        qsf_data = checker.parse_qsf(qsf)
        result = checker.build_result(build, qsf_data, checker.load_budget(budget_path))
        assert result["passed"]
        assert result["deltas_from_baseline"] == {"alms": 0, "m10ks": 0}
        assert not result["target_status"]["alms_met"]
        assert "95.54%" in checker.markdown(result)
        assert "90.26%" in checker.markdown(result)

        improved = copy.deepcopy(build)
        improved["usage"]["alms"]["used"] = 17_000
        improved_result = checker.build_result(improved, qsf_data, budget)
        assert improved_result["passed"]
        assert improved_result["deltas_from_baseline"]["alms"] == -655
        assert improved_result["target_status"]["alms_met"]

        alm_regression = copy.deepcopy(build)
        alm_regression["usage"]["alms"]["used"] = 17_656
        alm_result = checker.build_result(alm_regression, qsf_data, budget)
        assert not alm_result["passed"]
        assert any(
            "alms regressed to 17656" in error for error in alm_result["errors"]
        )

        ram_regression = copy.deepcopy(build)
        ram_regression["usage"]["m10ks"]["used"] = 287
        ram_result = checker.build_result(ram_regression, qsf_data, budget)
        assert not ram_result["passed"]
        assert any(
            "m10ks regressed to 287" in error for error in ram_result["errors"]
        )

        wrong_device = copy.deepcopy(build)
        wrong_device["device"] = "5CEBA5F23C8"
        assert not checker.build_result(wrong_device, qsf_data, budget)["passed"]
        wrong_version = copy.deepcopy(build)
        wrong_version["quartus"] = "22.1 Build 915"
        assert not checker.build_result(wrong_version, qsf_data, budget)["passed"]
        wrong_seed = dict(qsf_data, seed=10)
        assert not checker.build_result(build, wrong_seed, budget)["passed"]

        summary.write_text(
            summary_text(fitter_status="Failed"), encoding="utf-8", newline="\n"
        )
        assert_raises_value_error(
            lambda: checker.parse_fit_summary(summary), "fitter was not successful"
        )
        summary.write_text(
            summary_text().replace("Device : 5CEBA4F23C8\n", ""),
            encoding="utf-8",
            newline="\n",
        )
        assert_raises_value_error(lambda: checker.parse_fit_summary(summary), "found 0")
        summary.write_text(
            summary_text() + "Device : 5CEBA4F23C8\n",
            encoding="utf-8",
            newline="\n",
        )
        assert_raises_value_error(lambda: checker.parse_fit_summary(summary), "found 2")

        # Exercise comma parsing, CRLF input, the public CLI, and deterministic files.
        summary.write_bytes(summary_text().replace("\n", "\r\n").encode("utf-8"))
        command = [
            sys.executable,
            str(SCRIPT),
            "--summary",
            str(summary),
            "--qsf",
            str(qsf),
            "--budget",
            str(budget_path),
            "--json-out",
            str(json_out),
            "--markdown-out",
            str(markdown_out),
        ]
        first = subprocess.run(command, check=False, capture_output=True, text=True)
        assert first.returncode == 0, (first.stdout, first.stderr)
        first_json = json_out.read_bytes()
        first_markdown = markdown_out.read_bytes()
        second = subprocess.run(command, check=False, capture_output=True, text=True)
        assert second.returncode == 0, (second.stdout, second.stderr)
        assert json_out.read_bytes() == first_json
        assert markdown_out.read_bytes() == first_markdown

    print("Quartus resource parser and budget checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
