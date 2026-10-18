#!/usr/bin/env python3
"""Validate a Yardman private reference-asset fleet pack without importing media.

This gate is intentionally dependency-free so a private owner pack can be checked
outside GitHub. It verifies the pack manifest, recovered fleet provenance, GLB
rig hierarchy, interior evidence, duplicate model bytes, and protected reference
heroes. It does not claim Godot import/runtime success; that is a separate gate.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
import zipfile
from pathlib import Path

REQUIRED_PIVOTS = ("FrontWheelLeft", "FrontWheelRight", "RearWheelLeft", "RearWheelRight")
REFERENCE_HEROES = ("road_car.glb", "toyota_crown_2013.glb")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def glb_json(data: bytes) -> dict:
    if len(data) < 20:
        raise ValueError("GLB is too small")
    magic, version, total = struct.unpack_from("<III", data, 0)
    if magic != 0x46546C67 or version != 2 or total != len(data):
        raise ValueError("invalid GLB header")
    json_length, json_type = struct.unpack_from("<II", data, 12)
    if json_type != 0x4E4F534A:
        raise ValueError("first GLB chunk is not JSON")
    start = 20
    return json.loads(data[start : start + json_length])


def inspect_rig(data: bytes) -> dict:
    document = glb_json(data)
    nodes = document.get("nodes", [])
    by_name: dict[str, list[int]] = {}
    for index, node in enumerate(nodes):
        by_name.setdefault(str(node.get("name", "")), []).append(index)

    failures: list[str] = []
    if len(by_name.get("BodyShell", [])) != 1:
        failures.append("BodyShell_count")
    for pivot_name in REQUIRED_PIVOTS:
        pivot_ids = by_name.get(pivot_name, [])
        if len(pivot_ids) != 1:
            failures.append(pivot_name + "_count")
            continue
        spin_name = pivot_name + "Spin"
        spin_ids = by_name.get(spin_name, [])
        if len(spin_ids) != 1:
            failures.append(spin_name + "_count")
            continue
        children = set(nodes[pivot_ids[0]].get("children", []))
        if spin_ids[0] not in children:
            failures.append(spin_name + "_parent")

    names = [str(node.get("name", "")).lower() for node in nodes]
    interior_evidence = any(
        "interior" in name or "driverwheel" in name or "seat" in name
        for name in names
    )
    return {
        "nodes": len(nodes),
        "meshes": len(document.get("meshes", [])),
        "interior_evidence": interior_evidence,
        "failures": failures,
    }


def validate(pack_path: Path, expected_fleet: int) -> dict:
    result = {
        "format_version": 1,
        "tool": "yardman_private_fleet_pack_validator",
        "pack": pack_path.name,
        "pack_bytes": pack_path.stat().st_size,
        "pack_sha256": sha256(pack_path.read_bytes()),
        "manifest": {},
        "fleet": {},
        "reference_heroes": {},
    }
    with zipfile.ZipFile(pack_path) as archive:
        names = archive.namelist()
        name_set = set(names)
        result["zip_members"] = len(names)
        bad_crc = archive.testzip()
        result["zip_crc"] = "pass" if bad_crc is None else f"fail:{bad_crc}"

        manifest = json.loads(archive.read("manifest.json"))
        manifest_failures = []
        for entry in manifest.get("files", []):
            path = str(entry["path"])
            if path not in name_set:
                manifest_failures.append({"path": path, "reason": "missing"})
                continue
            data = archive.read(path)
            if len(data) != int(entry["bytes"]):
                manifest_failures.append({"path": path, "reason": "size"})
            if sha256(data) != str(entry["sha256"]):
                manifest_failures.append({"path": path, "reason": "sha256"})
        result["manifest"] = {
            "declared_files": len(manifest.get("files", [])),
            "verified": not manifest_failures,
            "failures": manifest_failures,
        }

        fleet_glbs = sorted(name for name in names if name.startswith("fleet_") and name.endswith(".glb"))
        fleet_provenance = sorted(
            name for name in names if name.startswith("fleet_") and name.endswith(".provenance.json")
        )
        entries = []
        runtime_ids = []
        glb_hashes: dict[str, list[str]] = {}
        interior_count = 0
        beta2_cross_source = 0
        beta2_pending = 0

        for glb_name in fleet_glbs:
            provenance_name = glb_name[:-4] + ".provenance.json"
            data = archive.read(glb_name)
            digest = sha256(data)
            glb_hashes.setdefault(digest, []).append(glb_name)
            failures = []
            if provenance_name not in name_set:
                entries.append({"glb": glb_name, "failures": ["missing_provenance"]})
                continue
            provenance = json.loads(archive.read(provenance_name))
            runtime_id = str(provenance.get("runtime_id", ""))
            runtime_ids.append(runtime_id)
            if provenance.get("source_lod0_sha256") != digest:
                failures.append("source_lod0_sha256_mismatch")
            if int(provenance.get("source_lod0_bytes", -1)) != len(data):
                failures.append("source_lod0_bytes_mismatch")
            try:
                rig = inspect_rig(data)
                failures.extend(rig["failures"])
                interior_count += int(rig["interior_evidence"])
            except Exception as exc:
                rig = {"error": str(exc)}
                failures.append("glb_parse_error")
            beta2 = provenance.get("beta2", {})
            if beta2.get("status") == "pending_cross_source_match":
                beta2_pending += 1
            elif beta2:
                beta2_cross_source += 1
            entries.append(
                {
                    "glb": glb_name,
                    "runtime_id": runtime_id,
                    "source_identity": provenance.get("source_identity"),
                    "source_unit": provenance.get("source_unit"),
                    "bytes": len(data),
                    "sha256": digest,
                    "beta2": beta2,
                    "rig": rig,
                    "failures": failures,
                }
            )

        duplicate_hashes = {digest: paths for digest, paths in glb_hashes.items() if len(paths) > 1}
        duplicate_runtime_ids = sorted({value for value in runtime_ids if runtime_ids.count(value) > 1})
        result["fleet"] = {
            "expected_heroes": expected_fleet,
            "hero_glbs": len(fleet_glbs),
            "provenance_files": len(fleet_provenance),
            "entries": entries,
            "all_entries_pass": all(not entry.get("failures") for entry in entries),
            "interior_evidence_count": interior_count,
            "unique_runtime_ids": len(set(runtime_ids)) == len(runtime_ids),
            "duplicate_runtime_ids": duplicate_runtime_ids,
            "duplicate_glb_hashes": duplicate_hashes,
            "beta2_matched_or_candidate": beta2_cross_source,
            "beta2_pending": beta2_pending,
        }

        for hero in REFERENCE_HEROES:
            if hero not in name_set:
                result["reference_heroes"][hero] = {"missing": True}
                continue
            data = archive.read(hero)
            result["reference_heroes"][hero] = {
                "bytes": len(data),
                "sha256": sha256(data),
                "rig": inspect_rig(data),
            }

        result["identity_safety"] = {
            "toyota_mark_x_named_asset_present": any("mark_x" in name.lower() for name in fleet_glbs),
            "port_royal_992_named_asset_present": any("992" in name.lower() for name in fleet_glbs),
            "chaser_road_car_present": "road_car.glb" in name_set,
            "cross_model_fallback_must_remain_disabled": True,
        }

    reference_pass = all(
        not entry.get("missing") and not entry["rig"]["failures"]
        for entry in result["reference_heroes"].values()
    )
    fleet = result["fleet"]
    result["accepted_structurally"] = all(
        [
            result["zip_crc"] == "pass",
            result["manifest"]["verified"],
            fleet["hero_glbs"] == expected_fleet,
            fleet["provenance_files"] == expected_fleet,
            fleet["all_entries_pass"],
            fleet["interior_evidence_count"] == expected_fleet,
            fleet["unique_runtime_ids"],
            not fleet["duplicate_glb_hashes"],
            reference_pass,
        ]
    )
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("pack", type=Path)
    parser.add_argument("--expected-fleet", type=int, default=45)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = validate(args.pack, args.expected_fleet)
    text = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
    print(text)
    return 0 if result["accepted_structurally"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
