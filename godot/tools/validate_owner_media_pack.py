#!/usr/bin/env python3
"""Validate Yardman's private owner-media pack before any owner APK export."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import zipfile
from pathlib import Path


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def validate(pack_path: Path, contract_path: Path) -> dict:
    contract = json.loads(contract_path.read_text(encoding="utf-8"))
    if int(contract.get("format_version", 0)) != 1:
        raise ValueError("Unsupported owner media contract format")
    if not pack_path.is_file():
        raise ValueError(f"Private owner-media pack is missing: {pack_path}")

    pack_bytes = pack_path.read_bytes()
    pack_sha = sha256_bytes(pack_bytes)
    expected_pack_sha = str(contract.get("pack_sha256", "")).lower()
    if expected_pack_sha and pack_sha != expected_pack_sha:
        raise ValueError(f"Private pack SHA mismatch: expected {expected_pack_sha}, got {pack_sha}")

    forbidden = [str(value).lower() for value in contract.get("forbidden_name_fragments", [])]
    with zipfile.ZipFile(pack_path) as archive:
        bad_crc = archive.testzip()
        if bad_crc is not None:
            raise ValueError(f"Private pack CRC failure: {bad_crc}")
        names = archive.namelist()
        lowered = [name.lower() for name in names]
        for fragment in forbidden:
            offenders = [names[index] for index, name in enumerate(lowered) if fragment and fragment in name]
            if offenders:
                raise ValueError(f"Forbidden private-media identity '{fragment}' present: {offenders[:5]}")

        if "manifest.json" not in names:
            raise ValueError("Private pack has no manifest.json")
        manifest = json.loads(archive.read("manifest.json"))
        if int(manifest.get("format_version", 0)) != 1:
            raise ValueError("Private pack manifest format is not v1")
        raw_records = manifest.get("files", [])
        if not isinstance(raw_records, list):
            raise ValueError("Private pack manifest files field is invalid")

        records: dict[str, dict] = {}
        for raw in raw_records:
            if not isinstance(raw, dict):
                continue
            path = str(raw.get("path", ""))
            if not path:
                continue
            if path in records:
                raise ValueError(f"Duplicate manifest path: {path}")
            records[path] = raw

        verified_records = 0
        for path, record in records.items():
            if path not in names:
                raise ValueError(f"Manifest-declared file missing from pack: {path}")
            payload = archive.read(path)
            expected_size = int(record.get("bytes", -1))
            expected_sha = str(record.get("sha256", "")).lower()
            if expected_size >= 0 and len(payload) != expected_size:
                raise ValueError(f"Manifest byte mismatch for {path}: {len(payload)} != {expected_size}")
            if len(expected_sha) != 64 or sha256_bytes(payload) != expected_sha:
                raise ValueError(f"Manifest SHA mismatch for {path}")
            verified_records += 1

        required_proof = []
        for required in contract.get("required_heroes", []):
            path = str(required.get("path", ""))
            if not path or path not in records:
                raise ValueError(f"Required hero is not manifest-backed: {path}")
            payload = archive.read(path)
            expected_size = int(required.get("bytes", -1))
            expected_sha = str(required.get("sha256", "")).lower()
            actual_sha = sha256_bytes(payload)
            if expected_size >= 0 and len(payload) != expected_size:
                raise ValueError(f"Required hero byte mismatch for {path}")
            if expected_sha and actual_sha != expected_sha:
                raise ValueError(f"Required hero SHA mismatch for {path}")
            required_proof.append({"path": path, "bytes": len(payload), "sha256": actual_sha})

        fleet_heroes = sorted(
            name for name in names
            if name.startswith("fleet_") and name.lower().endswith(".glb") and name in records
        )
        minimum = int(contract.get("minimum_fleet_heroes", 0))
        if len(fleet_heroes) < minimum:
            raise ValueError(f"Private fleet is incomplete: {len(fleet_heroes)} < {minimum}")

    return {
        "pack": pack_path.name,
        "pack_bytes": len(pack_bytes),
        "pack_sha256": pack_sha,
        "zip_members": len(names),
        "manifest_records_verified": verified_records,
        "fleet_heroes": len(fleet_heroes),
        "required_heroes": required_proof,
        "forbidden_identity_gate": "pass",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("pack", type=Path)
    parser.add_argument(
        "--contract",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "private_owner_media_contract.json",
    )
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        proof = validate(args.pack, args.contract)
    except Exception as exc:
        print(f"YARDMAN_OWNER_MEDIA_FAIL {exc}", file=sys.stderr)
        return 1
    encoded = json.dumps(proof, sort_keys=True)
    print(f"YARDMAN_OWNER_MEDIA_PASS {encoded}")
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(proof, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
