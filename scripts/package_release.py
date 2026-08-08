#!/usr/bin/env python3
"""Create a reproducible Analogue Pocket package and provenance sidecars."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import zipfile
from pathlib import Path
from typing import Iterable


CORE_DIRECTORY = "K3V.GBA"
CORE_AUTHOR = "K3V"
CORE_SHORTNAME = "K3V GBA"
ARCHIVE_BASENAME = "K3V.GBA"
PLATFORM_ID = "gba"
PACKAGE_ROOTS = ("Assets", "Cores", "Platforms")
PACKAGE_TREES = (
    ("Assets", "Assets"),
    (f"Cores/{CORE_DIRECTORY}", f"Cores/{CORE_DIRECTORY}"),
    ("Platforms", "Platforms"),
)
ZIP_TIMESTAMP = (1980, 1, 1, 0, 0, 0)
QUARTUS_VERSION = "21.1.1 Build 850"
QUARTUS_IMAGE = (
    "raetro/quartus@sha256:"
    "817a783727492269d33aa98c903e8efc216e95d785ee76bfc8f426eddee98d0b"
)
IMPORT_REPOSITORY = "https://github.com/mincer-ray/openfpga-GBA"
IMPORT_TAG = "v0.6.2"
IMPORT_COMMIT = "b08568fa60ff6f5f918cca5763f5b1923ed2d3db"
BIT_REVERSE_TABLE = bytes(int(f"{value:08b}"[::-1], 2) for value in range(256))


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_bitstream_pair(raw_bitstream: Path, pocket_bitstream: Path) -> None:
    if not raw_bitstream.is_file():
        raise ValueError(
            "Missing raw Quartus bitstream; refusing to package an unverified "
            f"Pocket image: {raw_bitstream}"
        )
    if raw_bitstream.stat().st_size != pocket_bitstream.stat().st_size:
        raise ValueError(
            "Raw and Pocket bitstreams differ in length: "
            f"{raw_bitstream.stat().st_size} != {pocket_bitstream.stat().st_size}"
        )

    with raw_bitstream.open("rb") as raw, pocket_bitstream.open("rb") as pocket:
        offset = 0
        while raw_chunk := raw.read(1024 * 1024):
            pocket_chunk = pocket.read(len(raw_chunk))
            if raw_chunk.translate(BIT_REVERSE_TABLE) != pocket_chunk:
                raise ValueError(
                    f"Pocket bitstream is not the byte-wise bit reversal of the raw RBF "
                    f"near offset {offset}"
                )
            offset += len(raw_chunk)


def load_metadata(package_root: Path) -> dict:
    core_json = package_root / "Cores" / CORE_DIRECTORY / "core.json"
    try:
        document = json.loads(core_json.read_text(encoding="utf-8"))
        metadata = document["core"]["metadata"]
        core_entries = document["core"]["cores"]
    except (OSError, KeyError, TypeError, json.JSONDecodeError) as error:
        raise ValueError(f"Invalid core definition {core_json}: {error}") from error

    expected = {
        "author": CORE_AUTHOR,
        "shortname": CORE_SHORTNAME,
    }
    for key, value in expected.items():
        if metadata.get(key) != value:
            raise ValueError(
                f"{core_json}: metadata.{key} must be {value!r}, "
                f"found {metadata.get(key)!r}"
            )

    platform_ids = metadata.get("platform_ids", [])
    if PLATFORM_ID not in platform_ids:
        raise ValueError(f"{core_json}: platform_ids must preserve {PLATFORM_ID!r}")

    version = metadata.get("version")
    release_date = metadata.get("date_release")
    if not isinstance(version, str) or not version:
        raise ValueError(f"{core_json}: metadata.version must be a non-empty string")
    if not isinstance(release_date, str) or not release_date:
        raise ValueError(f"{core_json}: metadata.date_release must be a non-empty string")

    if not core_entries or core_entries[0].get("filename") != "bitstream.rbf_r":
        raise ValueError(f"{core_json}: the default core must load bitstream.rbf_r")

    bitstream = package_root / "Cores" / CORE_DIRECTORY / "bitstream.rbf_r"
    if not bitstream.is_file() or bitstream.stat().st_size == 0:
        raise ValueError(f"Missing or empty synthesized bitstream: {bitstream}")

    return metadata


def collect_package_files(package_root: Path) -> list[tuple[Path, str]]:
    files: list[tuple[Path, str]] = []
    for source_name, archive_root in PACKAGE_TREES:
        root = package_root / source_name
        if not root.is_dir():
            raise ValueError(f"Missing required package directory: {root}")
        # Keep explicit directory entries so an intentionally empty Assets tree
        # and the selected core root survive extraction.
        files.append((root, f"{archive_root}/"))
        for path in root.rglob("*"):
            if path.is_symlink():
                raise ValueError(f"Package may not contain symbolic links: {path}")
            if path.is_file():
                archive_name = (
                    Path(archive_root) / path.relative_to(root)
                ).as_posix()
                files.append((path, archive_name))

    files.sort(key=lambda item: item[1])
    if not files:
        raise ValueError(f"No package files found below {package_root}")
    foreign_core = next(
        (
            archive_name
            for _, archive_name in files
            if archive_name.startswith("Cores/")
            and not archive_name.startswith(f"Cores/{CORE_DIRECTORY}/")
        ),
        None,
    )
    if foreign_core is not None:
        raise AssertionError(f"foreign core entered package manifest: {foreign_core}")
    return files


def zip_info(archive_name: str) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(archive_name, ZIP_TIMESTAMP)
    info.create_system = 3
    if archive_name.endswith("/"):
        info.compress_type = zipfile.ZIP_STORED
        info.external_attr = (0o40755 << 16) | 0x10
    else:
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o100644 << 16
    info.flag_bits |= 0x800
    return info


def write_deterministic_zip(
    destination: Path, files: Iterable[tuple[Path, str]]
) -> None:
    temporary = destination.with_name(destination.name + ".tmp")
    temporary.unlink(missing_ok=True)
    try:
        with zipfile.ZipFile(
            temporary,
            mode="w",
            compression=zipfile.ZIP_DEFLATED,
            compresslevel=9,
            allowZip64=True,
        ) as archive:
            for source, archive_name in files:
                contents = b"" if source.is_dir() else source.read_bytes()
                archive.writestr(
                    zip_info(archive_name),
                    contents,
                    compress_type=(
                        zipfile.ZIP_STORED
                        if archive_name.endswith("/")
                        else zipfile.ZIP_DEFLATED
                    ),
                    compresslevel=None if archive_name.endswith("/") else 9,
                )
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def git_value(project_root: Path, *arguments: str) -> str | None:
    try:
        result = subprocess.run(
            ["git", "-C", str(project_root), *arguments],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    return result.stdout.strip()


def relative_label(path: Path, project_root: Path) -> str:
    try:
        return path.resolve().relative_to(project_root.resolve()).as_posix()
    except ValueError:
        return path.name


def evidence_records(paths: Iterable[Path], project_root: Path) -> list[dict]:
    records = []
    seen: set[Path] = set()
    for candidate in paths:
        path = candidate if candidate.is_absolute() else project_root / candidate
        path = path.resolve()
        if path in seen or not path.is_file():
            continue
        seen.add(path)
        records.append(
            {
                "path": relative_label(path, project_root),
                "sha256": sha256_file(path),
                "size": path.stat().st_size,
            }
        )
    records.sort(key=lambda record: record["path"])
    return records


def default_evidence(project_root: Path) -> list[Path]:
    paths = [
        project_root / "src/fpga/build/output_files/ap_core.rbf",
        project_root / "src/fpga/build/output_files/ap_core.fit.summary",
        project_root / "src/fpga/build/output_files/ap_core.sta.summary",
        project_root / "src/fpga/build/output_files/ap_core.flow.rpt",
        project_root / "build_output/quartus-build.log",
        project_root / "build_output/prebuild-freshness.txt",
        project_root / "build_output/postbuild-freshness.txt",
        project_root / "test_results.txt",
        project_root / "diff-summary.txt",
        project_root / "AUDIT_REPORT.md",
    ]
    report_directory = project_root / "build_output/reports"
    if report_directory.is_dir():
        paths.extend(sorted(report_directory.glob("*.rpt")))
    evidence_directory = project_root / "dist/evidence"
    if evidence_directory.is_dir():
        paths.extend(sorted(path for path in evidence_directory.rglob("*") if path.is_file()))
    return paths


def require_complete_evidence(project_root: Path) -> None:
    required = [
        project_root / "build_output/quartus-build.log",
        project_root / "build_output/prebuild-freshness.txt",
        project_root / "build_output/postbuild-freshness.txt",
        project_root / "test_results.txt",
        project_root / "diff-summary.txt",
        project_root / "dist/evidence/K3V.GBA-import-to-v0.1.0.patch",
        project_root / "dist/evidence/source-status.txt",
        project_root / "dist/evidence/source-sha256.txt",
        project_root / "dist/evidence/test-results.txt",
        project_root / "dist/evidence/timing-summary.txt",
        project_root / "dist/evidence/toolchain-versions.txt",
    ]
    missing = [path for path in required if not path.is_file() or path.stat().st_size == 0]
    if missing:
        listing = ", ".join(relative_label(path, project_root) for path in missing)
        raise ValueError(f"Complete release evidence is missing or empty: {listing}")


def create_package(args: argparse.Namespace) -> tuple[Path, Path, Path]:
    project_root = args.project_root.resolve()
    package_root = project_root / "pkg"
    source_commit = git_value(project_root, "rev-parse", "HEAD")
    source_describe = git_value(project_root, "describe", "--always", "--dirty")
    source_status = git_value(project_root, "status", "--porcelain")
    output_dir = args.output_dir
    if not output_dir.is_absolute():
        output_dir = project_root / output_dir

    supplied_evidence = [
        path if path.is_absolute() else project_root / path for path in args.evidence
    ]
    missing_evidence = [path for path in supplied_evidence if not path.is_file()]
    if missing_evidence:
        missing = ", ".join(str(path) for path in missing_evidence)
        raise ValueError(f"Requested evidence file does not exist: {missing}")
    if args.require_complete_evidence:
        require_complete_evidence(project_root)

    metadata = load_metadata(package_root)
    verify_bitstream_pair(
        project_root / "src/fpga/build/output_files/ap_core.rbf",
        package_root / "Cores" / CORE_DIRECTORY / "bitstream.rbf_r",
    )
    files = collect_package_files(package_root)
    output_dir.mkdir(parents=True, exist_ok=True)
    archive = output_dir / f"{ARCHIVE_BASENAME}_{metadata['version']}.zip"
    checksum_file = archive.with_name(archive.name + ".sha256")
    provenance_file = archive.with_suffix(".provenance.json")

    write_deterministic_zip(archive, files)
    archive_hash = sha256_file(archive)
    checksum_file.write_text(
        f"{archive_hash}  {archive.name}\n", encoding="utf-8", newline="\n"
    )

    evidence = default_evidence(project_root)
    evidence.extend(supplied_evidence)
    provenance = {
        "schema": "k3v-gba-build-provenance-v1",
        "core": {
            "author": metadata["author"],
            "directory": CORE_DIRECTORY,
            "platform_ids": metadata["platform_ids"],
            "release_date": metadata["date_release"],
            "shortname": metadata["shortname"],
            "version": metadata["version"],
        },
        "package": {
            "file": archive.name,
            "roots": list(PACKAGE_ROOTS),
            "sha256": archive_hash,
            "size": archive.stat().st_size,
            "zip_entry_timestamp": "1980-01-01T00:00:00Z",
        },
        "packaged_files": [
            {
                "path": archive_name,
                "sha256": sha256_file(source),
                "size": source.stat().st_size,
            }
            for source, archive_name in files
            if source.is_file()
        ],
        "source": {
            "commit": source_commit,
            "describe": source_describe,
            "dirty": bool(source_status) if source_status is not None else None,
            "import_base": {
                "commit": IMPORT_COMMIT,
                "repository": IMPORT_REPOSITORY,
                "tag": IMPORT_TAG,
            },
        },
        "toolchain": {
            "quartus": QUARTUS_VERSION,
            "recommended_container": QUARTUS_IMAGE,
        },
        "evidence": evidence_records(evidence, project_root),
    }
    provenance_file.write_text(
        json.dumps(provenance, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
        newline="\n",
    )

    return archive, checksum_file, provenance_file


def parse_arguments() -> argparse.Namespace:
    default_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--project-root",
        type=Path,
        default=default_root,
        help="repository root (default: inferred from this script)",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("dist"),
        help="side-by-side ZIP and provenance output directory",
    )
    parser.add_argument(
        "--evidence",
        action="append",
        default=[],
        type=Path,
        help="additional build/test evidence to hash; may be repeated",
    )
    parser.add_argument(
        "--require-complete-evidence",
        action="store_true",
        help="fail unless the full audited release evidence set is present",
    )
    return parser.parse_args()


def main() -> int:
    try:
        archive, checksum, provenance = create_package(parse_arguments())
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    print(f"Package:    {archive}")
    print(f"SHA-256:   {checksum}")
    print(f"Provenance: {provenance}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
