#!/usr/bin/env python3
"""Validate and stage one exact private owner-media pack into a clean Yardman snapshot."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import tempfile
import zipfile
from pathlib import Path, PurePosixPath

from validate_owner_media_pack import validate

MARKER = ".yardman-owner-media-stage.json"
CONTROL_SUFFIXES = {".tres", ".uid"}
CONTROL_NAMES = {".gitkeep"}


def _safe_relative(name: str) -> Path:
    if not name or "\\" in name:
        raise ValueError(f"Unsafe owner-media path: {name!r}")
    pure = PurePosixPath(name)
    if pure.is_absolute() or any(part in {"", ".", ".."} for part in pure.parts):
        raise ValueError(f"Unsafe owner-media path: {name!r}")
    return Path(*pure.parts)


def _control_file(path: Path) -> bool:
    return path.name in CONTROL_NAMES or path.suffix.lower() in CONTROL_SUFFIXES


def _assert_clean_destination(destination: Path) -> None:
    if not destination.exists():
        return
    if not destination.is_dir():
        raise ValueError(f"Owner-media destination is not a directory: {destination}")
    marker = destination / MARKER
    prior_files: set[str] = set()
    if marker.is_file():
        prior = json.loads(marker.read_text(encoding="utf-8"))
        prior_files = {str(value) for value in prior.get("staged_files", [])}
    unexpected = []
    for path in destination.rglob("*"):
        if not path.is_file():
            continue
        relative = path.relative_to(destination).as_posix()
        if relative == MARKER or relative in prior_files or _control_file(path):
            continue
        unexpected.append(relative)
    if unexpected:
        raise ValueError(
            "Refusing to mix an exact owner-media pack with unrecognized existing files: "
            + ", ".join(sorted(unexpected)[:10])
        )


def stage(pack_path: Path, contract_path: Path, destination: Path) -> dict:
    proof = validate(pack_path, contract_path)
    _assert_clean_destination(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)

    with zipfile.ZipFile(pack_path) as archive:
        manifest_bytes = archive.read("manifest.json")
        manifest = json.loads(manifest_bytes)
        staged_names = []
        for raw in manifest.get("files", []):
            if not isinstance(raw, dict):
                continue
            name = str(raw.get("path", ""))
            _safe_relative(name)
            staged_names.append(name)
        if len(staged_names) != len(set(staged_names)):
            raise ValueError("Owner-media staging manifest contains duplicate paths")

        temporary = Path(tempfile.mkdtemp(prefix=destination.name + ".owner-media-", dir=destination.parent))
        backup = destination.with_name(destination.name + ".owner-media-backup")
        try:
            if destination.exists():
                for source in destination.rglob("*"):
                    if not source.is_file() or not _control_file(source):
                        continue
                    relative = source.relative_to(destination)
                    target = temporary / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source, target)

            for name in staged_names:
                relative = _safe_relative(name)
                target = temporary / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(name) as source, target.open("wb") as output:
                    shutil.copyfileobj(source, output, 1 << 20)

            (temporary / "manifest.json").write_bytes(manifest_bytes)
            receipt = {
                "format_version": 1,
                "pack": pack_path.name,
                "pack_sha256": proof["pack_sha256"],
                "manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest(),
                "manifest_records_verified": proof["manifest_records_verified"],
                "fleet_heroes": proof["fleet_heroes"],
                "owner_vehicle_heroes": proof["owner_vehicle_heroes"],
                "forbidden_identity_gate": proof["forbidden_identity_gate"],
                "staged_files": sorted(staged_names + ["manifest.json"]),
            }
            (temporary / MARKER).write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")

            if backup.exists():
                shutil.rmtree(backup)
            if destination.exists():
                destination.rename(backup)
            temporary.rename(destination)
            temporary = None
            if backup.exists():
                shutil.rmtree(backup)
            return receipt
        finally:
            if temporary is not None and temporary.exists():
                shutil.rmtree(temporary, ignore_errors=True)
            if backup.exists() and not destination.exists():
                backup.rename(destination)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pack", type=Path)
    parser.add_argument(
        "--contract",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "private_owner_media_contract.json",
    )
    parser.add_argument(
        "--destination",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "assets" / "user_reference",
    )
    args = parser.parse_args()
    os.umask(0o077)
    receipt = stage(args.pack, args.contract, args.destination)
    print("YARDMAN_OWNER_MEDIA_STAGE_PASS " + json.dumps(receipt, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
