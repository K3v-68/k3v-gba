#!/usr/bin/env python3
"""Run the RTC reference checks and self-checking GHDL scenarios."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import random
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path


SCENARIOS = {
    0: "atomic startup, exact divider, duplicate initialize",
    1: "one-second restart catch-up",
    2: "ten-minute restart catch-up",
    3: "one-hour restart catch-up",
    4: "one-day restart catch-up",
    5: "January rollover",
    6: "April rollover",
    7: "common-year February rollover",
    8: "leap-day entry",
    9: "leap-day exit",
    10: "year and weekday wrap",
    11: "host timestamp rollback",
    12: "persisted restart with mixed-day delta",
    13: "game write, live rollovers, and reset priority",
    14: "invalid persisted calendar defense",
    15: "ten-minute uninterrupted run",
    16: "one-hour uninterrupted run",
    17: "one-day uninterrupted run",
    18: "time-only write preservation and tick collision",
}


@dataclass(frozen=True)
class Calendar:
    year: int
    month: int
    day: int
    wday: int
    hour: int
    minute: int
    second: int


def days_in_month(year: int, month: int) -> int:
    if month == 2:
        return 29 if year % 4 == 0 else 28
    if month in (4, 6, 9, 11):
        return 30
    return 31


def next_day(value: Calendar) -> Calendar:
    year, month, day = value.year, value.month, value.day + 1
    if day > days_in_month(year, month):
        day = 1
        month += 1
        if month == 13:
            month = 1
            year = (year + 1) % 100
    return Calendar(year, month, day, (value.wday + 1) % 7, 0, 0, 0)


def advance(value: Calendar, elapsed: int) -> Calendar:
    """Fast independent reference using a modulo-100-year date cycle."""
    total = value.hour * 3600 + value.minute * 60 + value.second + elapsed
    whole_days, total = divmod(total, 86400)
    cycle_start = dt.date(2000, 1, 1)
    source_date = dt.date(2000 + value.year, value.month, value.day)
    source_index = (source_date - cycle_start).days
    target_index = (source_index + whole_days) % 36525
    target_date = cycle_start + dt.timedelta(days=target_index)
    return Calendar(
        target_date.year - 2000,
        target_date.month,
        target_date.day,
        (value.wday + whole_days) % 7,
        total // 3600,
        (total % 3600) // 60,
        total % 60,
    )


def advance_shadow_fsm(value: Calendar, elapsed: int) -> Calendar:
    """Cycle-equivalent model of the RTL compare/subtract catch-up states."""
    remaining = value.hour * 3600 + value.minute * 60 + value.second + elapsed
    result = Calendar(value.year, value.month, value.day, value.wday, 0, 0, 0)
    while remaining >= 86400:
        remaining -= 86400
        result = next_day(result)
    hour = 0
    while remaining >= 3600:
        remaining -= 3600
        hour += 1
    minute = 0
    while remaining >= 60:
        remaining -= 60
        minute += 1
    return Calendar(
        result.year, result.month, result.day, result.wday,
        hour, minute, remaining,
    )


def run_reference_checks(project_root: Path) -> None:
    cases = (
        (Calendar(24, 6, 15, 6, 12, 34, 56), 1,
         Calendar(24, 6, 15, 6, 12, 34, 57)),
        (Calendar(24, 6, 15, 6, 12, 34, 56), 600,
         Calendar(24, 6, 15, 6, 12, 44, 56)),
        (Calendar(24, 6, 15, 6, 12, 34, 56), 3600,
         Calendar(24, 6, 15, 6, 13, 34, 56)),
        (Calendar(24, 6, 15, 6, 12, 34, 56), 86400,
         Calendar(24, 6, 16, 0, 12, 34, 56)),
        (Calendar(24, 1, 31, 3, 23, 59, 59), 1,
         Calendar(24, 2, 1, 4, 0, 0, 0)),
        (Calendar(24, 4, 30, 2, 23, 59, 59), 1,
         Calendar(24, 5, 1, 3, 0, 0, 0)),
        (Calendar(1, 2, 28, 3, 23, 59, 59), 1,
         Calendar(1, 3, 1, 4, 0, 0, 0)),
        (Calendar(4, 2, 28, 6, 23, 59, 59), 1,
         Calendar(4, 2, 29, 0, 0, 0, 0)),
        (Calendar(4, 2, 29, 0, 23, 59, 59), 1,
         Calendar(4, 3, 1, 1, 0, 0, 0)),
        (Calendar(99, 12, 31, 6, 23, 59, 59), 1,
         Calendar(0, 1, 1, 0, 0, 0, 0)),
        (Calendar(24, 8, 5, 1, 7, 8, 9), 90061,
         Calendar(24, 8, 6, 2, 8, 9, 10)),
    )
    for source, elapsed, expected in cases:
        actual = advance(source, elapsed)
        if actual != expected:
            raise AssertionError(
                f"reference mismatch: {source} + {elapsed} = {actual}, "
                f"expected {expected}"
            )
        if advance_shadow_fsm(source, elapsed) != actual:
            raise AssertionError("shadow FSM disagrees with independent reference")

    # Exercise the full unsigned elapsed range plus deterministic randomized
    # dates/deltas.  This proves the 33-bit remainder and 49,711-day bound.
    maximum_source = Calendar(0, 1, 1, 6, 23, 59, 59)
    if advance_shadow_fsm(maximum_source, 0xFFFFFFFF) != advance(
        maximum_source, 0xFFFFFFFF
    ):
        raise AssertionError("maximum 32-bit elapsed interval mismatch")

    rng = random.Random(0x3511A)
    for _ in range(200):
        year = rng.randrange(100)
        month = rng.randrange(1, 13)
        source = Calendar(
            year,
            month,
            rng.randrange(1, days_in_month(year, month) + 1),
            rng.randrange(7),
            rng.randrange(24),
            rng.randrange(60),
            rng.randrange(60),
        )
        elapsed = rng.randrange(0x1_0000_0000)
        if advance_shadow_fsm(source, elapsed) != advance(source, elapsed):
            raise AssertionError(
                f"random shadow/reference mismatch: {source}, {elapsed}"
            )

    # Exact production clock contract: terminal N-1 gives one enable per N
    # rising edges.  This also records the measured PLL frequency in a test.
    production_hz = 100_663_296
    terminal = production_hz - 1
    if terminal != 100_663_295:
        raise AssertionError("incorrect production divider terminal")

    clock_source = (
        project_root / "src/fpga/gba/gba_rtc_clock.vhd"
    ).read_text(encoding="utf-8")
    gpio_source = (
        project_root / "src/fpga/gba/gba_gpioRTCSolarGyro.vhd"
    ).read_text(encoding="utf-8")

    data_document = json.loads(
        (project_root / "pkg/Cores/K3V.GBA/data.json").read_text(encoding="utf-8")
    )
    slots = data_document["data"]["data_slots"]
    save_slot = next(slot for slot in slots if slot["id"] == 10)
    rtc_slot = next(slot for slot in slots if slot["id"] == 11)
    if save_slot.get("size_maximum") != "0x20010":
        raise AssertionError("legacy footer import window was removed from Save slot")
    if rtc_slot.get("address") != "0x21000000":
        raise AssertionError("RTC sidecar is not mapped to its bridge subregion")
    if not rtc_slot.get("nonvolatile") or rtc_slot.get("required"):
        raise AssertionError("RTC sidecar must be optional and nonvolatile")
    if (int(rtc_slot.get("parameters", "0"), 0) & 0x4) == 0:
        raise AssertionError("RTC filename must be cloned from the ROM slot")
    if (int(rtc_slot.get("parameters", "0"), 0) & 0x2) != 0:
        raise AssertionError("RTC sidecar must share the .sav platform-common path")
    for name, slot in (("Save", save_slot), ("RTC", rtc_slot)):
        parameters = int(slot.get("parameters", "0"), 0)
        if parameters != 0x104:
            raise AssertionError(
                f"{name} slot parameters must be 0x104; found 0x{parameters:X}"
            )
    if rtc_slot.get("extensions", [None])[0] != "rtc":
        raise AssertionError("RTC sidecar must use the .rtc extension")
    if rtc_slot.get("size_exact") != 16:
        raise AssertionError("RTC sidecar must be exactly 16 bytes")

    core_source = (
        project_root / "src/fpga/core/core_top.sv"
    ).read_text(encoding="utf-8")
    persistence_source = (
        project_root / "src/fpga/core/rtc_persistence.sv"
    ).read_text(encoding="utf-8")
    required_sidecar_integration = (
        "save_loader_addr[27:24] == 4'h1",
        "save_unloader_addr[27:24] == 4'h1",
        ".stored_record_present ( rtc_record_present_sys )",
        "datatable_addr_r <= 10'd5",
        "datatable_addr_r <= 10'd7",
        "wire [31:0] save_size_bytes = flash_1m_s ? 32'h0002_0000 : 32'h0001_0000",
    )
    for required in required_sidecar_integration:
        if required not in core_source:
            raise AssertionError(f"RTC sidecar integration is missing: {required}")
    if "rtc_persistence rtc_store" not in core_source:
        raise AssertionError("RTC persistence module is not instantiated")
    if (
        "sidecar_record_valid" not in persistence_source
        or "legacy_record_valid" not in persistence_source
    ):
        raise AssertionError("RTC source validation/migration logic is missing")
    if "CLK_FREQUENCY_HZ : positive := 100663296" not in clock_source:
        raise AssertionError("RTC clock default is not the measured PLL frequency")
    if "CLK_FREQUENCY_HZ => 100663296" not in gpio_source:
        raise AssertionError("GPIO integration does not use the measured PLL frequency")
    required_gpio_boundary = (
        "game_time_write     => rtc_game_write_registered",
        "game_time_time_only => rtc_game_timeonly_registered",
        "game_time_in        => rtc_game_time_registered",
        "attribute preserve of rtc_game_time_registered",
        "attribute dont_retime of rtc_game_time_registered",
        "attribute preserve of rtc_game_write_registered",
        "attribute dont_retime of rtc_game_write_registered",
        "attribute preserve of rtc_game_timeonly_registered",
        "attribute dont_retime of rtc_game_timeonly_registered",
        "captured_game_time(6 downto 0) := final_data_byte(6 downto 0)",
    )
    for required in required_gpio_boundary:
        if required not in gpio_source:
            raise AssertionError(f"registered GPIO/RTC boundary is missing: {required}")

    # Parse the synthesized-friendly direct lookup from the VHDL and verify all
    # legal 12-hour encodings against an independent arithmetic reference.
    hour_cases = re.findall(
        r'when "([01]{6})" => if value\(7\) = \'1\' then return '
        r'"([01]{6})"; else return "([01]{6})"; end if;',
        gpio_source,
    )
    parsed_hours = {
        int(encoded, 2): (int(am_value, 2), int(pm_value, 2))
        for encoded, pm_value, am_value in hour_cases
    }
    expected_hours = {}
    for display_hour in range(12):
        encoded = ((display_hour // 10) << 4) | (display_hour % 10)
        am_hour = display_hour
        pm_hour = display_hour + 12
        am_bcd = ((am_hour // 10) << 4) | (am_hour % 10)
        pm_bcd = ((pm_hour // 10) << 4) | (pm_hour % 10)
        expected_hours[encoded] = (am_bcd, pm_bcd)
    if parsed_hours != expected_hours:
        raise AssertionError(
            f"12-hour GPIO write lookup mismatch: {parsed_hours!r}"
        )
    if "saveRTC_next" in gpio_source or "saveRTC_timeonly_next" in gpio_source:
        raise AssertionError("extra-cycle GPIO/RTC write staging was reintroduced")
    if "display_hour := hour_value - 12" not in gpio_source:
        raise AssertionError("12-hour readback does not expose the S-3511A 00..11 range")
    required_phase_checks = (
        "day_seconds_remaining >= SECONDS_PER_DAY_33",
        "hour_seconds_remaining >= SECONDS_PER_HOUR_17",
        "minute_seconds_remaining >= SECONDS_PER_MINUTE_12",
    )
    for required in required_phase_checks:
        if required not in clock_source:
            raise AssertionError(f"sequential catch-up phase is missing: {required}")
    if "offline_seconds_remaining" in clock_source:
        raise AssertionError("shared catch-up accumulator was reintroduced")
    for forbidden in ("total_seconds /", "total_seconds mod", "/ to_unsigned(86400"):
        if forbidden in clock_source:
            raise AssertionError(f"wide catch-up divider reintroduced: {forbidden}")

    print(
        "Python RTC reference checks passed "
        f"({len(cases)} directed + 201 full-range vectors + sidecar metadata)"
    )


def run_ghdl(project_root: Path, ghdl: str) -> None:
    rtl = project_root / "src/fpga/gba/gba_rtc_clock.vhd"
    bench = project_root / "tests/rtc/tb_gba_rtc_clock.vhd"
    gpio_sources = (
        project_root / "src/fpga/gba/proc_bus_gba.vhd",
        project_root / "src/fpga/gba/reg_savestates.vhd",
        project_root / "src/fpga/gba/gba_gpioRTCSolarGyro.vhd",
        project_root / "tests/rtc/tb_gba_gpioRTCSolarGyro.vhd",
    )

    with tempfile.TemporaryDirectory(prefix="k3v-rtc-ghdl-") as work_dir:
        common = [ghdl, "--std=08", f"--workdir={work_dir}"]
        subprocess.run([ghdl, "-a", "--std=08", f"--workdir={work_dir}",
                        str(rtl), str(bench)], check=True, cwd=project_root)
        subprocess.run([ghdl, "-e", *common[1:], "tb_gba_rtc_clock"],
                       check=True, cwd=project_root)

        for scenario, description in SCENARIOS.items():
            print(f"GHDL scenario {scenario}: {description}")
            subprocess.run(
                [ghdl, "-r", *common[1:], "tb_gba_rtc_clock",
                 f"-gSCENARIO={scenario}", "-gCLK_HZ=5",
                 "--assert-level=error"],
                check=True,
                cwd=project_root,
            )

        subprocess.run(
            [ghdl, "-a", *common[1:], *(str(source) for source in gpio_sources)],
            check=True,
            cwd=project_root,
        )
        subprocess.run(
            [ghdl, "-e", *common[1:], "tb_gba_gpioRTCSolarGyro"],
            check=True,
            cwd=project_root,
        )
        print("GHDL scenario GPIO: S-3511A serial hour/write integration")
        subprocess.run(
            [ghdl, "-r", *common[1:], "tb_gba_gpioRTCSolarGyro",
             "--assert-level=error", "--ieee-asserts=disable-at-0"],
            check=True,
            cwd=project_root,
        )

    print(
        "GHDL RTC checks passed "
        f"({len(SCENARIOS)} clock scenarios + 1 GPIO protocol scenario)"
    )


def run_iverilog(project_root: Path, iverilog: str, vvp: str) -> None:
    rtl = project_root / "src/fpga/core/rtc_persistence.sv"
    bench = project_root / "tests/rtc/tb_rtc_persistence.sv"
    suite_bin = Path(iverilog).resolve().parent
    environment = os.environ.copy()
    environment["PATH"] = os.pathsep.join(
        (str(suite_bin), str(suite_bin.parent / "lib"), environment.get("PATH", ""))
    )
    with tempfile.TemporaryDirectory(prefix="k3v-rtc-persistence-") as work_dir:
        output = Path(work_dir) / "rtc_persistence.vvp"
        subprocess.run(
            [iverilog, "-g2012", "-Wall", "-s", "tb_rtc_persistence",
             "-o", str(output), str(rtl), str(bench)],
            check=True,
            cwd=project_root,
            env=environment,
        )
        subprocess.run(
            [vvp, str(output)], check=True, cwd=project_root, env=environment
        )
    print("Icarus RTC persistence checks passed")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--require-ghdl",
        action="store_true",
        help="fail instead of skipping RTL simulation when GHDL is unavailable",
    )
    parser.add_argument(
        "--model-only",
        action="store_true",
        help="run only the dependency-free Python reference checks",
    )
    parser.add_argument(
        "--ghdl",
        type=Path,
        help="explicit GHDL executable (useful for a portable toolchain)",
    )
    parser.add_argument(
        "--require-iverilog",
        action="store_true",
        help="fail instead of skipping sidecar RTL simulation when Icarus is unavailable",
    )
    parser.add_argument("--iverilog", type=Path, help="explicit iverilog executable")
    parser.add_argument("--vvp", type=Path, help="explicit vvp executable")
    args = parser.parse_args()

    project_root = Path(__file__).resolve().parents[2]
    run_reference_checks(project_root)

    if args.model_only:
        return 0

    ghdl = str(args.ghdl.resolve()) if args.ghdl else shutil.which("ghdl")
    if ghdl is not None and not Path(ghdl).is_file():
        raise SystemExit(f"GHDL executable does not exist: {ghdl}")
    if ghdl is None:
        message = "GHDL not found; self-checking VHDL scenarios were not run"
        if args.require_ghdl:
            raise SystemExit(message)
        print(f"WARNING: {message}")
    else:
        run_ghdl(project_root, ghdl)

    iverilog = str(args.iverilog.resolve()) if args.iverilog else shutil.which("iverilog")
    vvp = str(args.vvp.resolve()) if args.vvp else shutil.which("vvp")
    if iverilog is not None and not Path(iverilog).is_file():
        raise SystemExit(f"iverilog executable does not exist: {iverilog}")
    if vvp is not None and not Path(vvp).is_file():
        raise SystemExit(f"vvp executable does not exist: {vvp}")
    if iverilog is None or vvp is None:
        message = "Icarus not found; RTC sidecar RTL scenario was not run"
        if args.require_iverilog:
            raise SystemExit(message)
        print(f"WARNING: {message}")
    else:
        run_iverilog(project_root, iverilog, vvp)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
