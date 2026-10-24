#!/usr/bin/env python3
"""Recover the exact export-visible owner Fleet64 from a previously validated APK.

This is a continuity path for CI when the original private import artifact has
expired. It does not reconstruct, rename, substitute, or regenerate vehicles.
The APK is treated as an immutable signed/exported source: exact packaged
PackedScenes, the exact runtime manifest, the private-pack manifest/provenance,
and any exported user-reference dependencies are copied back into the project.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import zipfile
from pathlib import Path, PurePosixPath

EXPECTED_COUNT = 64
PACKAGED_PREFIX = "assets/assets/owner_fleet_runtime/"
REFERENCE_PREFIX = "assets/assets/user_reference/"
RUNTIME_MANIFEST_ENTRY = "assets/data/owner_fleet_runtime_manifest.json"
PACK_CONTRACT_PATH = Path("data/owner_fleet_pack_contract.json")
RUNTIME_MANIFEST_PATH = Path("data/owner_fleet_runtime_manifest.json")
PACKAGED_ROOT = Path("assets/owner_fleet_runtime")
REFERENCE_ROOT = Path("assets/user_reference")
CROWN_HERO = "toyota_crown_2013.glb"
CHASER_HERO = "road_car.glb"


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _safe_relative(entry: str, prefix: str) -> Path:
    if not entry.startswith(prefix):
        raise ValueError(f"entry is outside expected prefix: {entry}")
    relative = PurePosixPath(entry[len(prefix):])
    if not relative.parts or relative.is_absolute() or ".." in relative.parts:
        raise ValueError(f"unsafe archive path: {entry}")
    return Path(*relative.parts)


def _read_json(zf: zipfile.ZipFile, entry: str) -> dict:
    try:
        value = json.loads(zf.read(entry).decode("utf-8"))
    except KeyError as exc:
        raise ValueError(f"missing APK resource: {entry}") from exc
    if not isinstance(value, dict):
        raise ValueError(f"APK resource is not a JSON object: {entry}")
    return value


def _load_project_contract(project_root: Path) -> dict:
    path = project_root / PACK_CONTRACT_PATH
    if not path.is_file():
        raise ValueError(f"missing current fleet contract: {path}")
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict) or int(value.get("format_version", 0)) != 1:
        raise ValueError("current owner fleet contract has unsupported format")
    ids = list(value.get("available_vehicle_ids", []))
    if int(value.get("available_vehicle_count", 0)) != EXPECTED_COUNT or len(ids) != EXPECTED_COUNT:
        raise ValueError("current owner fleet contract is not exactly 64 vehicles")
    if len(set(map(str, ids))) != EXPECTED_COUNT:
        raise ValueError("current owner fleet contract has duplicate vehicle ids")
    return value


def recover(apk_path: Path, project_root: Path) -> dict:
    apk_path = apk_path.resolve()
    project_root = project_root.resolve()
    if not apk_path.is_file():
        raise ValueError(f"owner APK does not exist: {apk_path}")
    contract = _load_project_contract(project_root)
    contract_ids = [str(value) for value in contract["available_vehicle_ids"]]

    with zipfile.ZipFile(apk_path) as zf:
        names = set(zf.namelist())
        runtime = _read_json(zf, RUNTIME_MANIFEST_ENTRY)
        if int(runtime.get("format_version", 0)) != 1:
            raise ValueError("recovery APK runtime manifest has unsupported format")
        runtime_ids = [str(value) for value in runtime.get("vehicle_ids", [])]
        vehicles = list(runtime.get("vehicles", []))
        if int(runtime.get("vehicle_count", 0)) != EXPECTED_COUNT or len(vehicles) != EXPECTED_COUNT:
            raise ValueError("recovery APK does not describe exactly 64 vehicles")
        if runtime_ids != contract_ids:
            raise ValueError("recovery APK Fleet64 ids differ from current owner contract")

        rows: dict[str, dict] = {}
        hero_names: set[str] = set()
        scene_entries: dict[str, str] = {}
        scene_hashes: dict[str, str] = {}
        for raw in vehicles:
            if not isinstance(raw, dict):
                raise ValueError("recovery APK vehicle manifest contains a non-object record")
            vehicle_id = str(raw.get("vehicle_id", ""))
            hero = str(raw.get("hero", ""))
            compiled = str(raw.get("compiled_resource", ""))
            if vehicle_id in rows or vehicle_id not in contract_ids:
                raise ValueError(f"duplicate or unknown vehicle id in recovery APK: {vehicle_id}")
            if not hero or "/" in hero or "\\" in hero or ".." in hero:
                raise ValueError(f"invalid hero filename for {vehicle_id}: {hero}")
            if hero in hero_names:
                raise ValueError(f"duplicate hero filename in recovery APK: {hero}")
            expected_compiled = f"res://assets/owner_fleet_runtime/{hero}.scn"
            if compiled != expected_compiled:
                raise ValueError(f"compiled scene path drifted for {vehicle_id}: {compiled}")
            apk_entry = PACKAGED_PREFIX + hero + ".scn"
            if apk_entry not in names:
                raise ValueError(f"recovery APK is missing packaged scene for {vehicle_id}: {apk_entry}")
            payload = zf.read(apk_entry)
            if len(payload) < 1024:
                raise ValueError(f"packaged scene is implausibly small for {vehicle_id}: {len(payload)} bytes")
            digest = _sha256_bytes(payload)
            if digest in scene_hashes.values():
                raise ValueError(f"duplicate packaged vehicle scene bytes detected for {vehicle_id}")
            rows[vehicle_id] = raw
            hero_names.add(hero)
            scene_entries[hero] = apk_entry
            scene_hashes[hero] = digest

        if set(rows) != set(contract_ids) or len(scene_entries) != EXPECTED_COUNT:
            raise ValueError("recovery APK Fleet64 inventory is incomplete")
        if str(rows["toyota_crown"].get("hero", "")) != CROWN_HERO:
            raise ValueError("recovery APK Crown hero identity drifted")
        chaser = rows.get("toyota_chaser_v", {})
        if str(chaser.get("hero", "")) != CHASER_HERO:
            raise ValueError("recovery APK Chaser hero identity drifted")
        if scene_hashes[CROWN_HERO] == scene_hashes[CHASER_HERO]:
            raise ValueError("Crown and Chaser packaged scenes are byte-identical")

        reference_entries = sorted(name for name in names if name.startswith(REFERENCE_PREFIX) and not name.endswith("/"))
        manifest_entry = REFERENCE_PREFIX + "manifest.json"
        if manifest_entry not in names:
            raise ValueError("recovery APK is missing private reference manifest")
        reference_manifest = _read_json(zf, manifest_entry)
        if int(reference_manifest.get("format_version", 0)) != 1:
            raise ValueError("private reference manifest has unsupported format")
        file_records = reference_manifest.get("files", [])
        if not isinstance(file_records, list):
            raise ValueError("private reference manifest files field is invalid")
        record_paths = [str(record.get("path", "")) for record in file_records if isinstance(record, dict)]
        for hero in hero_names:
            if record_paths.count(hero) != 1:
                raise ValueError(f"private reference manifest does not uniquely identify hero: {hero}")

        # Clear only the recovered private/export-visible fleet surfaces. Other
        # gameplay/world files are deliberately untouched.
        packaged_root = project_root / PACKAGED_ROOT
        reference_root = project_root / REFERENCE_ROOT
        if packaged_root.exists():
            shutil.rmtree(packaged_root)
        packaged_root.mkdir(parents=True)
        reference_root.mkdir(parents=True, exist_ok=True)

        for hero, apk_entry in sorted(scene_entries.items()):
            destination = packaged_root / (hero + ".scn")
            destination.write_bytes(zf.read(apk_entry))
        for entry in reference_entries:
            relative = _safe_relative(entry, REFERENCE_PREFIX)
            destination = reference_root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(zf.read(entry))
        runtime_path = project_root / RUNTIME_MANIFEST_PATH
        runtime_path.parent.mkdir(parents=True, exist_ok=True)
        runtime_path.write_text(json.dumps(runtime, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    recovered_files = sorted(packaged_root.glob("*.scn"))
    if len(recovered_files) != EXPECTED_COUNT:
        raise ValueError(f"recovered scene count is {len(recovered_files)}, expected {EXPECTED_COUNT}")
    disk_hashes = {_sha256_bytes(path.read_bytes()) for path in recovered_files}
    if len(disk_hashes) != EXPECTED_COUNT:
        raise ValueError("recovered Fleet64 contains duplicate scene payloads")
    crown_path = packaged_root / (CROWN_HERO + ".scn")
    chaser_path = packaged_root / (CHASER_HERO + ".scn")
    if not crown_path.is_file() or not chaser_path.is_file() or crown_path.read_bytes() == chaser_path.read_bytes():
        raise ValueError("recovered Crown identity is not distinct from Chaser")

    return {
        "apk_sha256": hashlib.sha256(apk_path.read_bytes()).hexdigest(),
        "vehicles": EXPECTED_COUNT,
        "unique_scene_hashes": len(disk_hashes),
        "crown_scene_bytes": crown_path.stat().st_size,
        "chaser_scene_bytes": chaser_path.stat().st_size,
        "crown_scene_sha256": _sha256_bytes(crown_path.read_bytes()),
        "chaser_scene_sha256": _sha256_bytes(chaser_path.read_bytes()),
        "reference_entries": len(reference_entries),
        "runtime_manifest": str(runtime_path),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    parser.add_argument("project_root", type=Path, nargs="?", default=Path("godot"))
    parser.add_argument("--expected-apk-sha256", default="")
    args = parser.parse_args()
    if args.expected_apk_sha256:
        actual = hashlib.sha256(args.apk.read_bytes()).hexdigest()
        if actual.lower() != args.expected_apk_sha256.lower():
            raise SystemExit(f"owner APK digest mismatch: expected {args.expected_apk_sha256} got {actual}")
    result = recover(args.apk, args.project_root)
    print("YARDMAN_FLEET64_APK_RECOVERY_PASS " + json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
