#!/usr/bin/env python3
"""Build the Yardman whole-fleet Beta1+Beta2 source-fusion matrix.

Identity matches and source-search completion are intentionally separate. A source
may be exhaustively searched without containing an exact matching model. That must
not block the fleet forever or be misreported as an unsearched source.
"""
from __future__ import annotations

import argparse
import json
import re
from collections import defaultdict
from pathlib import Path
from typing import Any

PORSCHE_RE = re.compile(
    r"(?:porsche|porsch|panamer|cayenne|carrera\s*gt|919\s*hybrid|918\s*spyder|\b911\b|\b992\b|gt3\s*rs|cayman|boxster|taycan|macan)",
    re.I,
)
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
    manifest: dict[str, Any],
    seed: dict[str, Any] | None = None,
    evidence: dict[str, Any] | None = None,
) -> tuple[dict[str, list[dict[str, Any]]], dict[str, Any]]:
    resolved: dict[str, list[dict[str, Any]]] = defaultdict(list)
    manifest_vehicles = manifest.get("sources", {}).get("car_parking_multiplayer", {}).get("vehicles", [])
    manifest_by_id = {
        int(v["catalog_id"]): v for v in manifest_vehicles if isinstance(v.get("catalog_id"), int)
    }
    unresolved_ids: set[int] = set(manifest_by_id)

    for vehicle in manifest_vehicles:
        catalog_id = vehicle.get("catalog_id")
        identity = normalized_identity(vehicle.get("identity"))
        if not identity:
            continue
        if isinstance(catalog_id, int):
            unresolved_ids.discard(catalog_id)
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
                "bundle_path": vehicle.get("bundle_path") or manifest_by_id.get(catalog_id, {}).get("bundle_path"),
                "identity_status": vehicle.get("identity_status"),
                "evidence": vehicle.get("evidence", "carparking_identity_seed"),
            }
            if not any(x.get("catalog_id") == catalog_id for x in resolved[identity]):
                resolved[identity].append(record)

    evidence_counts: dict[str, Any] = {}
    search_complete = False
    if evidence:
        evidence_counts = dict(evidence.get("counts", {}) or {})
        for vehicle in evidence.get("vehicles", []) or []:
            catalog_id = vehicle.get("catalog_id")
            if not isinstance(catalog_id, int):
                continue
            identity = normalized_identity(vehicle.get("identity"))
            status = str(vehicle.get("identity_status", ""))
            if identity:
                # Exact-bundle evidence supersedes older catalog-only identity for this catalog ID.
                for existing_identity in list(resolved):
                    resolved[existing_identity] = [
                        r for r in resolved[existing_identity] if r.get("catalog_id") != catalog_id
                    ]
                    if not resolved[existing_identity]:
                        del resolved[existing_identity]
                resolved[identity].append({
                    "catalog_id": catalog_id,
                    "bundle_path": vehicle.get("bundle_path") or manifest_by_id.get(catalog_id, {}).get("bundle_path"),
                    "identity_status": status,
                    "rights_status": vehicle.get("rights_status"),
                    "evidence": "exact_carparking_unityfs_bundle_decode",
                })
                unresolved_ids.discard(catalog_id)
            elif status.startswith("conflict_") or status.startswith("unresolved"):
                unresolved_ids.add(catalog_id)
        search_complete = (
            int(evidence_counts.get("current_car_bundles", 0) or 0) == len(manifest_by_id)
            and int(evidence_counts.get("unityfs_parse_errors", 0) or 0) == 0
        )

    summary = {
        "resolved_identities": len(resolved),
        "unresolved_bundle_ids": len(unresolved_ids),
        "search_complete": search_complete,
        "decoded_bundle_count": int(evidence_counts.get("current_car_bundles", 0) or 0),
        "excluded_porsche": int(evidence_counts.get("excluded_porsche", 0) or 0),
        "conflict_review_required": int(evidence_counts.get("conflict_review_required", 0) or 0),
    }
    return dict(resolved), summary


def collect_rr3(manifest: dict[str, Any]) -> tuple[dict[str, list[dict[str, Any]]], dict[str, Any]]:
    source = manifest.get("sources", {}).get("real_racing_3", {})
    resolved: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for vehicle in source.get("vehicles", []) or []:
        identity = normalized_identity(vehicle.get("identity") or vehicle.get("name"))
        if identity:
            resolved[identity].append(vehicle)
    status = str(source.get("status", "missing"))
    search_complete = bool(source.get("inventory_complete", False)) or status in {
        "inventory_complete", "fleet_inventory_complete", "decoded_inventory_complete"
    }
    summary = {
        "status": status,
        "migration_status": source.get("migration_status", "missing"),
        "logical_bytes": int(source.get("logical_bytes", 0) or 0),
        "split_parts": int(source.get("split_parts", 0) or 0),
        "resolved_identities": len(resolved),
        "search_complete": search_complete,
    }
    return dict(resolved), summary


def build(
    manifest: dict[str, Any],
    carparking_seed: dict[str, Any] | None = None,
    carparking_evidence: dict[str, Any] | None = None,
) -> dict[str, Any]:
    beta1 = collect_beta1(manifest)
    car_parking, cp_summary = collect_car_parking(manifest, carparking_seed, carparking_evidence)
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
                "car_parking_search_complete": cp_summary["search_complete"],
                "car_parking_exact_match": bool(car_parking.get(identity)),
                "real_racing_3_search_complete": rr3_summary["search_complete"],
                "real_racing_3_exact_match": bool(rr3.get(identity)),
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

        searches_complete = cp_summary["search_complete"] and rr3_summary["search_complete"]
        row["promotion_status"] = (
            "component_selection_ready" if searches_complete
            else "continue_beta2_source_search"
        )
        active.append(row)

    return {
        "format_version": 4,
        "policy": {
            "scope": "full_fleet_parallel_source_fusion",
            "crown007": "accepted_current_state_deprioritized_not_complete",
            "porsche": "excluded",
            "promotion_rule": "Search Beta1 and both Beta2 vehicle sources for every active vehicle. Search completion does not require an exact model match in every source; record no-match evidence instead of fabricating a substitute.",
        },
        "summary": {
            "active_identities": len(active),
            "deprioritized_reference_identities": len(deprioritized),
            "excluded_identities": len(excluded),
            "beta1_resolved_identities": len(beta1),
            "car_parking": cp_summary,
            "car_parking_seed_loaded": bool(carparking_seed),
            "car_parking_bundle_evidence_loaded": bool(carparking_evidence),
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
    parser.add_argument("--carparking-evidence", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    manifest = json.loads(args.migration_manifest.read_text(encoding="utf-8"))
    seed = json.loads(args.carparking_seed.read_text(encoding="utf-8")) if args.carparking_seed else None
    evidence = json.loads(args.carparking_evidence.read_text(encoding="utf-8")) if args.carparking_evidence else None
    result = build(manifest, seed, evidence)
    text = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
    print(text, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
