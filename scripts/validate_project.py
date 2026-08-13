#!/usr/bin/env python3
"""Validate K3V GBA identity, package metadata, artwork, and ZIP isolation."""

from __future__ import annotations

import argparse
import importlib.util
import json
import re
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path


CORE_DIRECTORY = "K3V.GBA"
CORE_URL = "https://github.com/K3v-68/k3v-gba"
SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
ICON_BYTES = 36 * 36 * 2
PLATFORM_IMAGE_BYTES = 521 * 165 * 2


def load_module(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ValueError(f"cannot import {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def validate_json(root: Path) -> None:
    documents = sorted((root / "pkg").rglob("*.json"))
    if not documents:
        raise ValueError("no package JSON files found")
    for path in documents:
        json.loads(path.read_text(encoding="utf-8"))
    print(f"Validated {len(documents)} package JSON files")


def validate_core(root: Path) -> None:
    core_root = root / "pkg/Cores" / CORE_DIRECTORY
    document = json.loads((core_root / "core.json").read_text(encoding="utf-8"))
    core = document["core"]
    metadata = core["metadata"]
    expected = {
        "author": "K3V",
        "shortname": "GBA",
        "url": CORE_URL,
    }
    for key, value in expected.items():
        if metadata.get(key) != value:
            raise ValueError(
                f"core metadata {key} must be {value!r}, found {metadata.get(key)!r}"
            )
    required_directory = f"{metadata['author']}.{metadata['shortname']}"
    if core_root.name != required_directory:
        raise ValueError(
            "core folder must match metadata author and shortname exactly: "
            f"{core_root.name!r} != {required_directory!r}"
        )
    version = metadata.get("version")
    if not isinstance(version, str) or SEMVER.fullmatch(version) is None:
        raise ValueError(f"core version must be semantic x.y.z, found {version!r}")
    if core["framework"]["hardware"].get("cartridge_adapter") != -1:
        raise ValueError("unused cartridge adapter must remain powered off (-1)")
    icon = (core_root / "icon.bin").read_bytes()
    if len(icon) != ICON_BYTES:
        raise ValueError(f"icon.bin is {len(icon)} bytes, expected {ICON_BYTES}")
    if any(icon[index] for index in range(1, len(icon), 2)):
        raise ValueError("icon.bin low bytes must be zero in monochrome format")
    platform_image = root / "pkg/Platforms/_images/gba.bin"
    if platform_image.stat().st_size != PLATFORM_IMAGE_BYTES:
        raise ValueError(
            f"shared platform image is {platform_image.stat().st_size} bytes, "
            f"expected {PLATFORM_IMAGE_BYTES}"
        )
    print("Validated K3V identity and Pocket artwork dimensions")


def validate_data_slots(root: Path) -> None:
    path = root / "pkg/Cores" / CORE_DIRECTORY / "data.json"
    slots = json.loads(path.read_text(encoding="utf-8"))["data"]["data_slots"]
    ids = [slot["id"] for slot in slots]
    addresses = [int(slot["address"], 0) for slot in slots]
    if len(ids) != len(set(ids)):
        raise ValueError("data slot IDs must be unique")
    if len(addresses) != len(set(addresses)):
        raise ValueError("data slot bridge addresses must be unique")

    by_id = {slot["id"]: slot for slot in slots}
    save_slot = by_id.get(10)
    rtc_slot = by_id.get(11)
    if save_slot is None or rtc_slot is None:
        raise ValueError("Save slot 10 and RTC sidecar slot 11 are required")
    if save_slot.get("size_maximum") != "0x20010":
        raise ValueError("Save slot must retain the legacy-footer import window")
    rtc_parameters = int(rtc_slot.get("parameters", "0"), 0)
    expected_rtc = {
        "required": False,
        "nonvolatile": True,
        "address": "0x21000000",
        "size_exact": 16,
    }
    for key, value in expected_rtc.items():
        if rtc_slot.get(key) != value:
            raise ValueError(
                f"RTC data slot {key} must be {value!r}, "
                f"found {rtc_slot.get(key)!r}"
            )
    if (rtc_parameters & 0x4) == 0:
        raise ValueError("RTC sidecar filename must be cloned from ROM slot 0")
    if (rtc_parameters & 0x2) != 0:
        raise ValueError("RTC sidecar must share the .sav platform-common path")
    if rtc_slot.get("extensions", [None])[0] != "rtc":
        raise ValueError("RTC sidecar's first extension must be rtc")
    print("Validated separate per-ROM RTC sidecar data slot")


def validate_manifest(root: Path) -> None:
    package_release = load_module(root / "scripts/package_release.py", "package_release")
    files = package_release.collect_package_files(root / "pkg")
    names = [archive_name for _, archive_name in files]
    required_asset_directories = {
        "Assets/",
        "Assets/gba/",
        "Assets/gba/common/",
    }
    missing_asset_directories = required_asset_directories.difference(names)
    if missing_asset_directories:
        raise ValueError(
            "package is missing required asset directories: "
            + ", ".join(sorted(missing_asset_directories))
        )
    if any(name.endswith(".gitkeep") for name in names):
        raise ValueError("placeholder files must not enter the release package")
    foreign = [
        name
        for name in names
        if name.startswith("Cores/")
        and not name.startswith(f"Cores/{CORE_DIRECTORY}/")
    ]
    if foreign:
        raise ValueError(f"foreign core paths entered package: {foreign}")

    with tempfile.TemporaryDirectory(prefix="k3v-package-manifest-") as directory:
        archive_path = Path(directory) / "manifest.zip"
        second_archive_path = Path(directory) / "manifest-second.zip"
        package_release.write_deterministic_zip(archive_path, files)
        package_release.write_deterministic_zip(second_archive_path, files)
        if archive_path.read_bytes() != second_archive_path.read_bytes():
            raise ValueError("package ZIP generation is not deterministic")
        with zipfile.ZipFile(archive_path) as archive:
            archived_names = archive.namelist()
        if archived_names != names:
            raise ValueError("ZIP entries differ from the validated package manifest")
        for directory in required_asset_directories:
            info = archive.getinfo(directory)
            if not info.is_dir():
                raise ValueError(f"ZIP entry is not a directory: {directory}")
        if any(name.startswith("Cores/Spiritualized") for name in archived_names):
            raise ValueError("rejected compatibility core leaked into K3V package")
    print(f"Validated K3V-only package manifest ({len(names)} ZIP entries)")


def tracked_paths(root: Path) -> list[Path]:
    result = subprocess.run(
        ["git", "-C", str(root), "ls-files"],
        check=True,
        capture_output=True,
        text=True,
    )
    return [root / line for line in result.stdout.splitlines() if line]


def validate_public_identity(root: Path) -> None:
    # Import provenance is retained in NOTICE, README's lineage section, and the
    # release sidecar generator. It must not appear in K3V package metadata.
    allow = {
        root / "NOTICE",
        root / "README.md",
        root / "scripts/package_release.py",
    }
    textual_suffixes = {
        ".json", ".md", ".txt", ".tcl", ".py", ".ps1", ".sh", ".sv", ".v", ".vhd"
    }
    # Assemble the forbidden spellings so this validator can scan itself without
    # treating its own rules as stale public identity references.
    stale_tokens = (
        "-".join(("mincer", "ray")),
        ".".join(("k3v", "k3v_gba")),
        "_".join(("REPAIR", "REPORT.md")),
    )
    offenders: list[str] = []
    candidates = set(tracked_paths(root))
    candidates.update(
        path
        for path in (
            root / "README.md",
            root / "AUDIT_REPORT.md",
            root / "pkg/Cores/K3V.GBA/core.json",
            root / "pkg/Cores/K3V.GBA/info.txt",
        )
        if path.is_file()
    )
    for path in candidates:
        if path in allow or path.suffix.lower() not in textual_suffixes or not path.is_file():
            continue
        contents = path.read_text(encoding="utf-8", errors="ignore").lower()
        for token in stale_tokens:
            if token.lower() in contents:
                offenders.append(f"{path.relative_to(root)}: {token}")
    if offenders:
        raise ValueError("stale public identity references: " + ", ".join(offenders))
    print("Validated public K3V identity and provenance boundary")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--project-root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
    )
    args = parser.parse_args()
    root = args.project_root.resolve()
    try:
        validate_json(root)
        validate_core(root)
        validate_data_slots(root)
        validate_manifest(root)
        validate_public_identity(root)
    except (KeyError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"validation failure: {error}", file=sys.stderr)
        return 1
    print("All project validation checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
