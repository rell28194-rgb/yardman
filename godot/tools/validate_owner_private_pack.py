#!/usr/bin/env python3
"""Validate and optionally install Yardman's exact owner private asset pack.

Public CI intentionally does not contain owner-private media. That makes public
CI useful for source/runtime health, but never sufficient evidence for an owner
visual/vehicle APK. This gate is for owner-candidate builds only.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import sys
import tempfile
import zipfile

HERE = Path(__file__).resolve()
GODOT_ROOT = HERE.parents[1]
DEFAULT_CONTRACT = GODOT_ROOT / "docs" / "owner_private_pack_contract.json"
DEFAULT_INSTALL_ROOT = GODOT_ROOT / "assets" / "user_reference"


class OwnerPackError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise OwnerPackError(f"cannot read JSON {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise OwnerPackError(f"JSON root must be an object: {path}")
    return value


def load_contract(path: Path = DEFAULT_CONTRACT) -> dict:
    contract = load_json(path)
    if int(contract.get("format_version", 0)) != 1:
        raise OwnerPackError("unsupported owner private-pack contract version")
    archive = contract.get("archive")
    manifest = contract.get("manifest")
    if not isinstance(archive, dict) or not isinstance(manifest, dict):
        raise OwnerPackError("owner private-pack contract is missing archive/manifest sections")
    return contract


def _safe_member_name(name: str) -> bool:
    path = PurePosixPath(name)
    return (
        bool(name)
        and not path.is_absolute()
        and ".." not in path.parts
        and "\\" not in name
        and not name.startswith("/")
    )


def _manifest_records(manifest: dict) -> dict[str, dict]:
    records = manifest.get("files")
    if not isinstance(records, list) or not records:
        raise OwnerPackError("private pack manifest has no file records")
    indexed: dict[str, dict] = {}
    for raw in records:
        if not isinstance(raw, dict):
            raise OwnerPackError("private pack manifest contains a non-object file record")
        name = str(raw.get("path", ""))
        if not _safe_member_name(name):
            raise OwnerPackError(f"unsafe or empty manifest path: {name!r}")
        if name in indexed:
            raise OwnerPackError(f"duplicate manifest path: {name}")
        sha = str(raw.get("sha256", "")).lower()
        if len(sha) != 64 or any(c not in "0123456789abcdef" for c in sha):
            raise OwnerPackError(f"invalid manifest SHA-256 for {name}")
        size = raw.get("bytes")
        if not isinstance(size, int) or size < 0:
            raise OwnerPackError(f"invalid manifest byte count for {name}")
        indexed[name] = raw
    return indexed


def validate_manifest_contract(manifest: dict, contract: dict, member_names: set[str]) -> None:
    expected = contract["manifest"]
    owner = manifest.get("owner_recovery")
    if not isinstance(owner, dict):
        raise OwnerPackError("private pack manifest is missing owner_recovery")

    checks = {
        "pack_id": manifest.get("pack_id"),
        "private_pack_revision": manifest.get("private_pack_revision"),
        "available_vehicle_count": owner.get("available_vehicle_count"),
    }
    for key, actual in checks.items():
        wanted = expected.get(key)
        if actual != wanted:
            raise OwnerPackError(f"owner private-pack {key} mismatch: expected {wanted!r}, got {actual!r}")

    for key in ("scrapped_vehicle_ids", "held_missing_vehicle_ids"):
        actual = sorted(str(v) for v in owner.get(key, []))
        wanted = sorted(str(v) for v in expected.get(key, []))
        if actual != wanted:
            raise OwnerPackError(f"owner private-pack {key} mismatch: expected {wanted}, got {actual}")

    required = [str(v) for v in contract.get("required_owner_heroes", [])]
    missing = [name for name in required if name not in member_names]
    if missing:
        raise OwnerPackError(f"owner private pack is missing required hero media: {missing}")

    forbidden = [str(v) for v in contract.get("forbidden_hero_paths", [])]
    present = [name for name in forbidden if name in member_names]
    if present:
        raise OwnerPackError(f"owner private pack contains forbidden vehicle media: {present}")


def validate_archive(archive_path: Path, contract: dict) -> dict:
    if not archive_path.is_file():
        raise OwnerPackError(f"owner private pack not found: {archive_path}")
    expected_archive = contract["archive"]
    actual_size = archive_path.stat().st_size
    expected_size = int(expected_archive.get("bytes", -1))
    if actual_size != expected_size:
        raise OwnerPackError(
            f"owner private-pack size mismatch: expected {expected_size}, got {actual_size}"
        )
    actual_sha = sha256_file(archive_path)
    expected_sha = str(expected_archive.get("sha256", "")).lower()
    if actual_sha != expected_sha:
        raise OwnerPackError(
            f"owner private-pack SHA-256 mismatch: expected {expected_sha}, got {actual_sha}"
        )

    try:
        with zipfile.ZipFile(archive_path) as archive:
            corrupt = archive.testzip()
            if corrupt is not None:
                raise OwnerPackError(f"owner private-pack CRC failure: {corrupt}")
            names = archive.namelist()
            unsafe = [name for name in names if not _safe_member_name(name)]
            if unsafe:
                raise OwnerPackError(f"owner private pack has unsafe archive paths: {unsafe[:5]}")
            if len(names) != len(set(names)):
                raise OwnerPackError("owner private pack contains duplicate ZIP member names")
            if "manifest.json" not in names:
                raise OwnerPackError("owner private pack is missing manifest.json")
            manifest_raw = archive.read("manifest.json")
            manifest = json.loads(manifest_raw.decode("utf-8"))
            if not isinstance(manifest, dict):
                raise OwnerPackError("owner private-pack manifest root is not an object")
            records = _manifest_records(manifest)
            validate_manifest_contract(manifest, contract, set(names))

            # Every declared private-pack file is content-addressed. This prevents
            # a pack with the right label but old/partial vehicle bytes from being
            # accepted as an owner candidate.
            for name, record in records.items():
                if name not in names:
                    raise OwnerPackError(f"manifest file missing from private pack: {name}")
                info = archive.getinfo(name)
                if info.file_size != int(record["bytes"]):
                    raise OwnerPackError(
                        f"private-pack byte mismatch for {name}: expected {record['bytes']}, got {info.file_size}"
                    )
                digest = hashlib.sha256(archive.read(name)).hexdigest()
                if digest != str(record["sha256"]).lower():
                    raise OwnerPackError(f"private-pack SHA mismatch for {name}")
    except (zipfile.BadZipFile, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise OwnerPackError(f"invalid owner private-pack ZIP/manifest: {exc}") from exc

    return {
        "archive": str(archive_path),
        "archive_sha256": actual_sha,
        "archive_bytes": actual_size,
        "pack_id": manifest["pack_id"],
        "private_pack_revision": manifest["private_pack_revision"],
        "available_vehicle_count": int(manifest["owner_recovery"]["available_vehicle_count"]),
        "manifest_files": len(records),
    }


def validate_graphics_authority(project_root: Path, contract: dict) -> None:
    graphics = contract.get("graphics_authority", {})
    required = graphics.get("required_runtime_files", []) if isinstance(graphics, dict) else []
    missing = [str(rel) for rel in required if not (project_root / str(rel)).is_file()]
    if missing:
        raise OwnerPackError(f"validated graphics runtime files are missing: {missing}")


def validate_installed_root(root: Path, contract: dict) -> dict:
    manifest_path = root / "manifest.json"
    manifest = load_json(manifest_path)
    files = _manifest_records(manifest)
    present = {
        path.relative_to(root).as_posix()
        for path in root.rglob("*")
        if path.is_file()
    }
    validate_manifest_contract(manifest, contract, present)
    for name, record in files.items():
        path = root / name
        if not path.is_file():
            raise OwnerPackError(f"installed owner pack is missing {name}")
        if path.stat().st_size != int(record["bytes"]):
            raise OwnerPackError(f"installed owner-pack byte mismatch for {name}")
        if sha256_file(path) != str(record["sha256"]).lower():
            raise OwnerPackError(f"installed owner-pack SHA mismatch for {name}")
    for forbidden in contract.get("forbidden_hero_paths", []):
        if (root / str(forbidden)).exists():
            raise OwnerPackError(f"forbidden vehicle media survived owner-pack install: {forbidden}")
    return {
        "root": str(root),
        "pack_id": manifest.get("pack_id"),
        "available_vehicle_count": manifest.get("owner_recovery", {}).get("available_vehicle_count"),
    }


def install_verified_archive(archive_path: Path, target: Path, contract: dict) -> dict:
    # Destructive replacement is intentionally limited to the canonical Godot
    # private-reference directory. This removes stale Mark X/992 files and old
    # Crown-only pack residue instead of merging over them.
    expected_target = DEFAULT_INSTALL_ROOT.resolve()
    if target.resolve() != expected_target:
        raise OwnerPackError(
            f"refusing non-canonical install target {target}; expected {DEFAULT_INSTALL_ROOT}"
        )
    validate_archive(archive_path, contract)
    target.parent.mkdir(parents=True, exist_ok=True)
    temp = target.parent / f".{target.name}.owner-pack-install"
    backup = target.parent / f".{target.name}.owner-pack-backup"
    for path in (temp, backup):
        if path.exists():
            shutil.rmtree(path)
    temp.mkdir(parents=True)
    try:
        with zipfile.ZipFile(archive_path) as archive:
            archive.extractall(temp)
        validate_installed_root(temp, contract)
        if target.exists():
            target.rename(backup)
        temp.rename(target)
        validate_installed_root(target, contract)
        if backup.exists():
            shutil.rmtree(backup)
    except Exception:
        if target.exists() and backup.exists():
            shutil.rmtree(target)
            backup.rename(target)
        if temp.exists():
            shutil.rmtree(temp)
        raise
    return validate_installed_root(target, contract)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", nargs="?", type=Path)
    parser.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
    parser.add_argument("--project-root", type=Path, default=GODOT_ROOT)
    parser.add_argument("--installed-root", type=Path)
    parser.add_argument("--install", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        contract = load_contract(args.contract)
        validate_graphics_authority(args.project_root, contract)
        result: dict = {}
        if args.install:
            if args.archive is None:
                raise OwnerPackError("--install requires the owner private-pack archive path")
            result = install_verified_archive(args.archive, DEFAULT_INSTALL_ROOT, contract)
        elif args.archive is not None:
            result = validate_archive(args.archive, contract)
        elif args.installed_root is not None:
            result = validate_installed_root(args.installed_root, contract)
        else:
            raise OwnerPackError("provide an archive path, --installed-root, or --install")
    except OwnerPackError as exc:
        print(f"YARDMAN_OWNER_PRIVATE_PACK_FAIL {exc}", file=sys.stderr)
        return 1
    print("YARDMAN_OWNER_PRIVATE_PACK_PASS " + json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
