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
PACKAGE_SCRIPT = ROOT / "scripts/package_release.py"


def load_checker():
    spec = importlib.util.spec_from_file_location("check_quartus_resources", SCRIPT)
    if spec is None or spec.loader is None:
        raise AssertionError(f"cannot import {SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_package_script():
    spec = importlib.util.spec_from_file_location("package_release", PACKAGE_SCRIPT)
    if spec is None or spec.loader is None:
        raise AssertionError(f"cannot import {PACKAGE_SCRIPT}")
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
        "limits": {"alms": 17_655, "m10ks": 285},
        "targets": {"alms": 17_000},
        "tradeoffs": {
            "embedded_cdc_fifos": {
                "maximum_added_m10ks": 7,
                "requires_alm_reduction": True,
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
    package_script = load_package_script()
    checked_budget = checker.load_budget(
        ROOT / "benchmarks/quartus-resource-budget.json"
    )
    assert checked_budget["tradeoffs"]["embedded_cdc_fifos"][
        "requires_alm_reduction"
    ] is True
    with tempfile.TemporaryDirectory(prefix="k3v-resource-test-") as directory:
        temp = Path(directory)
        summary = temp / "ap_core.fit.summary"
        qsf = temp / "ap_core.qsf"
        budget_path = temp / "resource-budget.json"
        json_out = temp / "resource-usage.json"
        markdown_out = temp / "resource-usage.md"
        github_summary = temp / "github-summary.md"

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
        assert result["release_commit"] == budget["release_commit"]
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

        improved_with_ram_trade = copy.deepcopy(improved)
        improved_with_ram_trade["usage"]["m10ks"]["used"] = 285
        assert checker.build_result(
            improved_with_ram_trade, qsf_data, budget
        )["passed"]

        unpaid_ram_trade = copy.deepcopy(build)
        unpaid_ram_trade["usage"]["m10ks"]["used"] = 285
        unpaid_result = checker.build_result(unpaid_ram_trade, qsf_data, budget)
        assert not unpaid_result["passed"]
        assert any(
            "M10K tradeoff requires ALM usage below the baseline" in error
            for error in unpaid_result["errors"]
        )

        alm_regression = copy.deepcopy(build)
        alm_regression["usage"]["alms"]["used"] = 17_656
        alm_result = checker.build_result(alm_regression, qsf_data, budget)
        assert not alm_result["passed"]
        assert any(
            "alms regressed to 17656" in error for error in alm_result["errors"]
        )

        ram_regression = copy.deepcopy(build)
        ram_regression["usage"]["m10ks"]["used"] = 286
        ram_result = checker.build_result(ram_regression, qsf_data, budget)
        assert not ram_result["passed"]
        assert any(
            "m10ks regressed to 286" in error for error in ram_result["errors"]
        )

        wrong_device = copy.deepcopy(build)
        wrong_device["device"] = "5CEBA5F23C8"
        assert not checker.build_result(wrong_device, qsf_data, budget)["passed"]
        wrong_version = copy.deepcopy(build)
        wrong_version["quartus"] = "22.1 Build 915"
        assert not checker.build_result(wrong_version, qsf_data, budget)["passed"]
        prefix_collision = copy.deepcopy(build)
        prefix_collision["quartus"] = "21.1.1 Build 8500 06/23/2022 SJ Lite Edition"
        assert not checker.build_result(prefix_collision, qsf_data, budget)["passed"]
        wrong_seed = dict(qsf_data, seed=10)
        assert not checker.build_result(build, wrong_seed, budget)["passed"]

        malformed = copy.deepcopy(budget)
        malformed["limits"]["m10ks"] = 286
        budget_path.write_text(
            json.dumps(malformed, indent=2) + "\n", encoding="utf-8", newline="\n"
        )
        assert_raises_value_error(
            lambda: checker.load_budget(budget_path),
            "limits.m10ks must equal the baseline plus declared tradeoffs",
        )
        malformed = copy.deepcopy(budget)
        malformed["limits"]["m10ks"] = 284
        budget_path.write_text(
            json.dumps(malformed, indent=2) + "\n", encoding="utf-8", newline="\n"
        )
        assert_raises_value_error(
            lambda: checker.load_budget(budget_path),
            "limits.m10ks must equal the baseline plus declared tradeoffs",
        )
        malformed = copy.deepcopy(budget)
        malformed["targets"]["alms"] = True
        budget_path.write_text(
            json.dumps(malformed, indent=2) + "\n", encoding="utf-8", newline="\n"
        )
        assert_raises_value_error(
            lambda: checker.load_budget(budget_path),
            "targets.alms must be a non-negative integer",
        )
        malformed = copy.deepcopy(budget)
        malformed["tradeoffs"]["embedded_cdc_fifos"][
            "maximum_added_m10ks"
        ] = 31
        budget_path.write_text(
            json.dumps(malformed, indent=2) + "\n", encoding="utf-8", newline="\n"
        )
        assert_raises_value_error(
            lambda: checker.load_budget(budget_path),
            "declared M10K tradeoffs exceed the device capacity",
        )
        malformed = copy.deepcopy(budget)
        del malformed["release_commit"]
        budget_path.write_text(
            json.dumps(malformed, indent=2) + "\n", encoding="utf-8", newline="\n"
        )
        assert_raises_value_error(
            lambda: checker.load_budget(budget_path),
            "top-level keys must be",
        )
        malformed = copy.deepcopy(budget)
        malformed["unexpected"] = 1
        budget_path.write_text(
            json.dumps(malformed, indent=2) + "\n", encoding="utf-8", newline="\n"
        )
        assert_raises_value_error(
            lambda: checker.load_budget(budget_path),
            "top-level keys must be",
        )
        budget_path.write_text(
            json.dumps(budget, indent=2) + "\n", encoding="utf-8", newline="\n"
        )

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

        # Parse/configuration errors must still leave deterministic evidence in
        # every CI output, including the append-only GitHub job summary.
        malformed = copy.deepcopy(budget)
        malformed["limits"]["m10ks"] = 286
        budget_path.write_text(
            json.dumps(malformed, indent=2) + "\n", encoding="utf-8", newline="\n"
        )
        error_json = temp / "resource-error.json"
        error_markdown = temp / "resource-error.md"
        error_command = [
            sys.executable,
            str(SCRIPT),
            "--summary",
            str(summary),
            "--qsf",
            str(qsf),
            "--budget",
            str(budget_path),
            "--json-out",
            str(error_json),
            "--markdown-out",
            str(error_markdown),
            "--github-summary",
            str(github_summary),
        ]
        first_error = subprocess.run(
            error_command, check=False, capture_output=True, text=True
        )
        assert first_error.returncode == 2, (first_error.stdout, first_error.stderr)
        error_document = json.loads(error_json.read_text(encoding="utf-8"))
        assert error_document["passed"] is False
        assert error_document["status"] == "invalid"
        assert "Resource check could not be completed" in error_markdown.read_text(
            encoding="utf-8"
        )
        first_error_json = error_json.read_bytes()
        first_error_markdown = error_markdown.read_bytes()
        first_github_summary = github_summary.read_bytes()
        second_error = subprocess.run(
            error_command, check=False, capture_output=True, text=True
        )
        assert second_error.returncode == 2, (second_error.stdout, second_error.stderr)
        assert error_json.read_bytes() == first_error_json
        assert error_markdown.read_bytes() == first_error_markdown
        assert github_summary.read_bytes() == first_github_summary * 2

        budget_path.write_text(
            json.dumps(budget, indent=2) + "\n", encoding="utf-8", newline="\n"
        )
        summary.write_text(
            summary_text().replace("Device : 5CEBA4F23C8\n", ""),
            encoding="utf-8",
            newline="\n",
        )
        parse_error_json = temp / "parse-error.json"
        parse_error_markdown = temp / "parse-error.md"
        parse_github_summary = temp / "parse-github-summary.md"
        parse_error_command = [
            sys.executable,
            str(SCRIPT),
            "--summary",
            str(summary),
            "--qsf",
            str(qsf),
            "--budget",
            str(budget_path),
            "--json-out",
            str(parse_error_json),
            "--markdown-out",
            str(parse_error_markdown),
            "--github-summary",
            str(parse_github_summary),
        ]
        parse_error = subprocess.run(
            parse_error_command, check=False, capture_output=True, text=True
        )
        assert parse_error.returncode == 2, (parse_error.stdout, parse_error.stderr)
        assert json.loads(parse_error_json.read_text(encoding="utf-8"))["status"] == (
            "invalid"
        )
        assert parse_error_markdown.read_bytes() == parse_github_summary.read_bytes()

        evidence = package_script.default_evidence(ROOT)
        assert ROOT / "benchmarks/quartus-resource-budget.json" in evidence
        assert ROOT / "build_output/resource-usage.json" in evidence
        try:
            package_script.require_complete_evidence(temp)
        except ValueError as error:
            message = str(error)
            assert "benchmarks/quartus-resource-budget.json" in message
            assert "build_output/resource-usage.json" in message
        else:
            raise AssertionError("expected incomplete package evidence to be rejected")

        shell_build = (ROOT / "scripts/build.sh").read_text(encoding="utf-8")
        assert '"$RESOURCE_JSON" "$RESOURCE_MARKDOWN"' in shell_build
        powershell_build = (ROOT / "scripts/build.ps1").read_text(encoding="utf-8")
        assert "Remove-Item -LiteralPath $ResourceJson" in powershell_build
        assert "Remove-Item -LiteralPath $ResourceMarkdown" in powershell_build

    print("Quartus resource parser and budget checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
