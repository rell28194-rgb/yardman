#!/usr/bin/env python3
"""Build a whole-fleet Yardman Beta1+Beta2 source-fusion matrix.

The planner is fleet-wide. A vehicle is not promoted merely because one usable
source exists. Recovered Car Parking identity seeds can be overlaid onto the
older migration manifest as decoding advances. Crown007 is accepted in its
current state and deprioritized, not permanently complete. Porsche is excluded.
"""
from __future__ import annotations

import argparse
import json
import re
from collections import defaultdict
from pathlib import Path
from typing import Any

PORSCHE_RE = re.compile(r"(?:porsche|\b911\b|\b992\b|cayman|boxster|panamera|taycan|macan)", re.I)
CROWN_RE = re.compile(r"toyota\s*crown", re.I)


def normalized_identity(value: Any) -> str:
    text = str(value or "").strip()
    if text.lower() == "ae86":
        return "AE86"
    return text


def rights_state(identity: str) -> str:
    if PORSCHE_RE.search(identity):
        return "excluded_porsche"
    if CROWN_RE.search(identity):
        return "deprioritized_reference_crown007"
    return "owner_authorized_non_porsche"


def collect_beta1(manifest: dict[str, Any]) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = defaultdict(lambda: {
        "source": "CarX Drift",
        "source_variants": 0,
        "source_units": [],
        "best_object_record_count": 0,
        "interior_available": False,
        "camera_points_available": False,
        "engine_node_available": False,
    })
    vehicles = manifest.get("sources", {}).get("carx_drift", {}).get("vehicles", [])
    for vehicle in vehicles:
        identity = normalized_identity(vehicle.get("identity"))
        if not identity:
            continue
        record = result[identity]
        record["source_variants"] += 1
        record["best_object_record_count"] = max(
            int(record["best_object_record_count"]), int(vehicle.get("object_records", 0) or 0)
        )
        record["interior_available"] = bool(record["interior_available"] or vehicle.get("has_interior", False))
        record["camera_points_available"] = bool(record["camera_points_available"] or vehicle.get("has_camera_points", False))
        record["engine_node_available"] = bool(record["engine_node_available"] or vehicle.get("has_engine_node", False))
        source_unit = str(vehicle.get("source_unit", "")).strip()
        if source_unit and source_unit not in record["source_units"]:
            record["source_units"].append(source_unit)
    return dict(result)


def collect_car_parking(
    manifest: dict[str, Any], seed: dict[str, Any] | None = None
) -> tuple[dict[str, list[dict[str, Any]]], int]:
    resolved: dict[str, list[dict[str, Any]]] = defaultdict(list)
    unresolved_ids: set[int] = set()
    vehicles = manifest.get("sources", {}).get("car_parking_multiplayer", {}).get("vehicles", [])
    for vehicle in vehicles:
        catalog_id = vehicle.get("catalog_id")
        identity = normalized_identity(vehicle.get("identity"))
        if not identity:
            if isinstance(catalog_id, int):
                unresolved_ids.add(catalog_id)
            continue
        resolved[identity].append({
            "catalog_id": catalog_id,
            "bundle_path": vehicle.get("bundle_path"),
            "identity_status": vehicle.get("identity_status"),
            "evidence": "full_fleet_migration_manifest",
        })

    if seed:
        for vehicle in seed.get("exact_identities", []) or []:
            identity = normalized_identity(vehicle.get("identity"))
            catalog_id = vehicle.get("catalog_id")
            if not identity or not isinstance(catalog_id, int):
                continue
            unresolved_ids.discard(catalog_id)
            record = {
                "catalog_id": catalog_id,
                "bundle_path": vehicle.get("bundle_path"),
                "identity_status": vehicle.get("identity_status"),
                "evidence": vehicle.get("evidence", "carparking_identity_seed"),
            }
            if not any(x.get("catalog_id") == catalog_id for x in resolved[identity]):
                resolved[identity].append(record)
    return dict(resolved), len(unresolved_ids)


def collect_rr3(manifest: dict[str, Any]) -> tuple[dict[str, list[dict[str, Any]]], dict[str, Any]]:
    source = manifest.get("sources", {}).get("real_racing_3", {})
    resolved: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for vehicle in source.get("vehicles", []) or []:
        identity = normalized_identity(vehicle.get("identity") or vehicle.get("name"))
        if not identity:
            continue
        resolved[identity].append(vehicle)
    summary = {
        "status": source.get("status", "missing"),
        "migration_status": source.get("migration_status", "missing"),
        "logical_bytes": int(source.get("logical_bytes", 0) or 0),
        "split_parts": int(source.get("split_parts", 0) or 0),
        "resolved_identities": len(resolved),
    }
    return dict(resolved), summary


def build(manifest: dict[str, Any], carparking_seed: dict[str, Any] | None = None) -> dict[str, Any]:
    beta1 = collect_beta1(manifest)
    car_parking, cp_unresolved = collect_car_parking(manifest, carparking_seed)
    rr3, rr3_summary = collect_rr3(manifest)

    identities = sorted(set(beta1) | set(car_parking) | set(rr3), key=str.casefold)
    active: list[dict[str, Any]] = []
    deprioritized: list[dict[str, Any]] = []
    excluded: list[dict[str, Any]] = []
    for identity in identities:
        state = rights_state(identity)
        row = {
            "identity": identity,
            "rights_status": state,
            "beta1": beta1.get(identity, {"status": "exact_identity_not_resolved"}),
            "beta2": {
                "car_parking": car_parking.get(identity, []),
                "real_racing_3": rr3.get(identity, []),
                "car_parking_identity_resolved": bool(car_parking.get(identity)),
                "real_racing_3_identity_resolved": bool(rr3.get(identity)),
            },
        }
        if state == "excluded_porsche":
            row["promotion_status"] = "excluded"
            excluded.append(row)
            continue
        if state == "deprioritized_reference_crown007":
            row["promotion_status"] = "accepted_current_state_deprioritized"
            row["remaining_work"] = "opportunistic/shared-fleet improvements allowed; do not block fleet expansion"
            deprioritized.append(row)
            continue
        beta2_complete = row["beta2"]["car_parking_identity_resolved"] and row["beta2"]["real_racing_3_identity_resolved"]
        row["promotion_status"] = "component_selection_ready" if beta2_complete else "continue_beta2_decode_and_component_search"
        active.append(row)

    return {
        "format_version": 3,
        "policy": {
            "scope": "full_fleet_parallel_source_fusion",
            "crown007": "accepted_current_state_deprioritized_not_complete",
            "porsche": "excluded",
            "promotion_rule": "Every active vehicle must use a recorded Beta1+Beta2 search before production promotion; do not stop at the first usable source.",
        },
        "summary": {
            "active_identities": len(active),
            "deprioritized_reference_identities": len(deprioritized),
            "excluded_identities": len(excluded),
            "beta1_resolved_identities": len(beta1),
            "car_parking_resolved_identities": len(car_parking),
            "car_parking_unresolved_bundle_ids": cp_unresolved,
            "car_parking_seed_loaded": bool(carparking_seed),
            "real_racing_3": rr3_summary,
        },
        "active": active,
        "deprioritized_reference": deprioritized,
        "excluded": excluded,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("migration_manifest", type=Path)
    parser.add_argument("--carparking-seed", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    manifest = json.loads(args.migration_manifest.read_text(encoding="utf-8"))
    seed = json.loads(args.carparking_seed.read_text(encoding="utf-8")) if args.carparking_seed else None
    result = build(manifest, seed)
    text = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
    print(text, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
