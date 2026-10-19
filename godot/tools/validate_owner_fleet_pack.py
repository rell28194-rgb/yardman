#!/usr/bin/env python3
import argparse
import hashlib
import json
import zipfile
from pathlib import Path


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def hero_candidates(vehicle_id: str) -> tuple[str, ...]:
    if vehicle_id == "toyota_crown":
        return ("toyota_crown_2013.glb",)
    if vehicle_id == "toyota_chaser_v":
        return ("road_car.glb",)
    return (f"{vehicle_id}.glb", f"fleet_{vehicle_id}.glb")


def validate(pack_path: Path, contract_path: Path) -> dict:
    contract = json.loads(contract_path.read_text(encoding="utf-8"))
    if contract.get("format_version") != 1:
        raise ValueError("owner fleet contract format is invalid")
    ids = contract.get("selectable_vehicle_ids")
    if not isinstance(ids, list) or len(ids) != 64 or len(set(ids)) != 64:
        raise ValueError("owner fleet contract must contain 64 unique selectors")
    if int(contract.get("selectable_vehicle_count", -1)) != 64:
        raise ValueError("owner fleet declared selector count is not 64")
    if pack_path.stat().st_size != int(contract.get("pack_bytes", -1)):
        raise ValueError("private fleet pack byte count differs from owner contract")
    actual_pack_sha = sha256_file(pack_path)
    if actual_pack_sha != str(contract.get("pack_sha256", "")).lower():
        raise ValueError("private fleet pack SHA-256 differs from owner contract")

    forbidden = set(contract.get("scrapped_vehicle_ids", [])) | set(contract.get("held_missing_vehicle_ids", []))
    if set(ids) & forbidden:
        raise ValueError("scrapped/held selector leaked into owner roster")

    with zipfile.ZipFile(pack_path) as archive:
        bad = archive.testzip()
        if bad is not None:
            raise ValueError(f"private fleet pack CRC failure: {bad}")
        names = archive.namelist()
        if "manifest.json" not in names:
            raise ValueError("private fleet pack has no manifest.json")
        manifest = json.loads(archive.read("manifest.json"))
        if manifest.get("format_version") != 1:
            raise ValueError("private fleet manifest format is invalid")
        records = manifest.get("files")
        if not isinstance(records, list):
            raise ValueError("private fleet manifest has no file records")
        by_path = {}
        for record in records:
            path = str(record.get("path", ""))
            if not path or path in by_path:
                raise ValueError(f"ambiguous private fleet manifest path: {path}")
            by_path[path] = record

        heroes = {}
        for vehicle_id in ids:
            hits = [candidate for candidate in hero_candidates(vehicle_id) if candidate in by_path and candidate in names]
            if len(hits) != 1:
                raise ValueError(f"{vehicle_id} does not resolve to one dedicated hero: {hits}")
            hero = hits[0]
            record = by_path[hero]
            payload = archive.read(hero)
            if payload[:4] != b"glTF":
                raise ValueError(f"{vehicle_id} hero is not a GLB: {hero}")
            if len(payload) != int(record.get("bytes", -1)):
                raise ValueError(f"{vehicle_id} hero byte count differs from manifest")
            digest = hashlib.sha256(payload).hexdigest()
            if digest != str(record.get("sha256", "")).lower():
                raise ValueError(f"{vehicle_id} hero SHA-256 differs from manifest")
            heroes[vehicle_id] = hero

        lowered = [name.lower() for name in names]
        for vehicle_id in forbidden:
            token = vehicle_id.lower()
            if any(token in name for name in lowered):
                raise ValueError(f"forbidden owner vehicle media is present: {vehicle_id}")

    return {
        "status": "PASS",
        "selectors": len(ids),
        "verified_heroes": len(heroes),
        "pack_bytes": pack_path.stat().st_size,
        "pack_sha256": actual_pack_sha,
        "manifest_records": len(by_path),
        "zip_members": len(names),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("pack", type=Path)
    parser.add_argument("contract", type=Path)
    args = parser.parse_args()
    result = validate(args.pack, args.contract)
    print("YARDMAN_OWNER_FLEET_PACK_PASS " + json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
