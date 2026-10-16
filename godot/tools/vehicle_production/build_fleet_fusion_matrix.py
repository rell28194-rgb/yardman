#!/usr/bin/env python3
"""Build the Yardman whole-fleet Beta1+Beta2 source-fusion matrix.

Identity matches, source inventory completion, rights state, and per-identity
search completion are deliberately separate. Brand eligibility is source-scoped:
assets already present in the owner-authorized Yardman project source pool may be
evaluated normally. Source-game maps/world geography remain excluded.
"""
from __future__ import annotations

import argparse
import json
import re
from collections import defaultdict
from pathlib import Path
from typing import Any

CROWN_RE = re.compile(r"toyota\s*crown", re.I)
PORSCHE_RE = re.compile(r"\bporsche\b", re.I)


def normalized_identity(value: Any) -> str:
    text = str(value or "").strip()
    if text.lower() == "ae86":
        return "AE86"
    return text


def rights_state(identity: str, porsche_authorized: bool = True) -> str:
    """Return current production state; legacy flag is intentionally ignored."""
    del porsche_authorized
    if CROWN_RE.search(identity):
        return "deprioritized_reference_crown007"
    return "active_vehicle"


def _remove_catalog_id(
    resolved: dict[str, list[dict[str, Any]]], catalog_id: int
) -> None:
    for identity in list(resolved):
        resolved[identity] = [
            row for row in resolved[identity] if row.get("catalog_id") != catalog_id
        ]
        if not resolved[identity]:
            del resolved[identity]


def collect_beta1(manifest: dict[str, Any]) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = defaultdict(
        lambda: {
            "source": "CarX Drift",
            "source_variants": 0,
            "source_units": [],
            "best_object_record_count": 0,
            "interior_available": False,
            "camera_points_available": False,
            "engine_node_available": False,
        }
    )
    vehicles = manifest.get("sources", {}).get("carx_drift", {}).get("vehicles", [])
    for vehicle in vehicles:
        identity = normalized_identity(vehicle.get("identity"))
        if not identity:
            continue
        record = result[identity]
        record["source_variants"] += 1
        record["best_object_record_count"] = max(
            int(record["best_object_record_count"]),
            int(vehicle.get("object_records", 0) or 0),
        )
        record["interior_available"] = bool(
            record["interior_available"] or vehicle.get("has_interior", False)
        )
        record["camera_points_available"] = bool(
            record["camera_points_available"]
            or vehicle.get("has_camera_points", False)
        )
        record["engine_node_available"] = bool(
            record["engine_node_available"] or vehicle.get("has_engine_node", False)
        )
        source_unit = str(vehicle.get("source_unit", "")).strip()
        if source_unit and source_unit not in record["source_units"]:
            record["source_units"].append(source_unit)
    return dict(result)


def collect_car_parking(
    manifest: dict[str, Any],
    seed: dict[str, Any] | None = None,
    evidence: dict[str, Any] | None = None,
    rights_refresh: dict[str, Any] | None = None,
    porsche_authorized: bool = True,
) -> tuple[dict[str, list[dict[str, Any]]], dict[str, Any]]:
    del porsche_authorized
    resolved: dict[str, list[dict[str, Any]]] = defaultdict(list)
    manifest_vehicles = (
        manifest.get("sources", {})
        .get("car_parking_multiplayer", {})
        .get("vehicles", [])
    )
    manifest_by_id = {
        int(v["catalog_id"]): v
        for v in manifest_vehicles
        if isinstance(v.get("catalog_id"), int)
    }
    unresolved_ids: set[int] = set(manifest_by_id)

    for vehicle in manifest_vehicles:
        catalog_id = vehicle.get("catalog_id")
        identity = normalized_identity(vehicle.get("identity"))
        if not identity:
            continue
        if isinstance(catalog_id, int):
            unresolved_ids.discard(catalog_id)
        resolved[identity].append(
            {
                "catalog_id": catalog_id,
                "bundle_path": vehicle.get("bundle_path"),
                "identity_status": vehicle.get("identity_status"),
                "rights_status": rights_state(identity),
                "evidence": "full_fleet_migration_manifest",
            }
        )

    if seed:
        for vehicle in seed.get("exact_identities", []) or []:
            identity = normalized_identity(vehicle.get("identity"))
            catalog_id = vehicle.get("catalog_id")
            if not identity or not isinstance(catalog_id, int):
                continue
            unresolved_ids.discard(catalog_id)
            record = {
                "catalog_id": catalog_id,
                "bundle_path": vehicle.get("bundle_path")
                or manifest_by_id.get(catalog_id, {}).get("bundle_path"),
                "identity_status": vehicle.get("identity_status"),
                "rights_status": rights_state(identity),
                "evidence": vehicle.get("evidence", "carparking_identity_seed"),
            }
            if not any(
                row.get("catalog_id") == catalog_id for row in resolved[identity]
            ):
                resolved[identity].append(record)

    evidence_counts: dict[str, Any] = {}
    parse_complete = False
    historical_excluded_porsche = 0
    if evidence:
        evidence_counts = dict(
            evidence.get("counts", {}) or evidence.get("decode", {}) or {}
        )
        for vehicle in evidence.get("vehicles", []) or []:
            catalog_id = vehicle.get("catalog_id")
            if not isinstance(catalog_id, int):
                continue
            identity = normalized_identity(vehicle.get("identity"))
            status = str(vehicle.get("identity_status", ""))
            if identity:
                _remove_catalog_id(resolved, catalog_id)
                resolved[identity].append(
                    {
                        "catalog_id": catalog_id,
                        "bundle_path": vehicle.get("bundle_path")
                        or manifest_by_id.get(catalog_id, {}).get("bundle_path"),
                        "identity_status": status,
                        "rights_status": rights_state(identity),
                        "evidence": "exact_carparking_unityfs_bundle_decode",
                    }
                )
                unresolved_ids.discard(catalog_id)
            elif status.startswith("conflict_") or status.startswith("unresolved"):
                unresolved_ids.add(catalog_id)

        current_bundles = int(evidence_counts.get("current_car_bundles", 0) or 0)
        parse_errors = int(
            evidence_counts.get("unityfs_parse_errors", 0)
            or evidence_counts.get("unityfs_parse_failures", 0)
            or 0
        )
        parse_complete = current_bundles == len(manifest_by_id) and parse_errors == 0
        historical_excluded_porsche = int(
            evidence_counts.get("excluded_porsche", 0) or 0
        )

    refreshed_porsche_ids: set[int] = set()
    expected_refresh_ids: set[int] = set()
    if rights_refresh:
        expected_refresh_ids = {
            int(value)
            for value in rights_refresh.get("historical_excluded_catalog_ids", [])
            if isinstance(value, int)
        }
        for vehicle in rights_refresh.get("refreshed", []) or []:
            catalog_id = vehicle.get("catalog_id")
            identity = normalized_identity(vehicle.get("normalized_identity"))
            if not isinstance(catalog_id, int) or not identity:
                continue
            _remove_catalog_id(resolved, catalog_id)
            resolved[identity].append(
                {
                    "catalog_id": catalog_id,
                    "bundle_path": vehicle.get("bundle_path")
                    or manifest_by_id.get(catalog_id, {}).get("bundle_path"),
                    "identity_status": vehicle.get("identity_status"),
                    "rights_status": rights_state(identity),
                    "generation_status": vehicle.get("generation_status"),
                    "decision": vehicle.get("decision"),
                    "exact_bundle_model_directories": vehicle.get(
                        "exact_bundle_model_directories", []
                    ),
                    "audio_evidence": vehicle.get("audio_evidence", []),
                    "evidence": rights_refresh.get(
                        "checkpoint", "carparking_historical_rights_refresh"
                    ),
                }
            )
            unresolved_ids.discard(catalog_id)
            if PORSCHE_RE.search(identity):
                refreshed_porsche_ids.add(catalog_id)

    porsche_refresh_complete = bool(
        expected_refresh_ids and expected_refresh_ids <= refreshed_porsche_ids
    )

    return dict(resolved), {
        "resolved_identities": len(resolved),
        "unresolved_bundle_ids": len(unresolved_ids),
        "parse_complete": parse_complete,
        "decoded_bundle_count": int(
            evidence_counts.get("current_car_bundles", 0) or 0
        ),
        "historical_excluded_porsche": historical_excluded_porsche,
        "porsche_authorized": True,
        "porsche_refresh_loaded": bool(rights_refresh),
        "porsche_refreshed_catalog_ids": sorted(refreshed_porsche_ids),
        "porsche_refresh_complete": porsche_refresh_complete,
        "porsche_refresh_required": False,
        "current_brand_filter": "none",
        "conflict_review_required": int(
            evidence_counts.get("conflict_review_required", 0) or 0
        ),
    }


def collect_rr3_manifest(
    manifest: dict[str, Any],
) -> tuple[dict[str, list[dict[str, Any]]], dict[str, Any]]:
    source = manifest.get("sources", {}).get("real_racing_3", {})
    resolved: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for vehicle in source.get("vehicles", []) or []:
        identity = normalized_identity(vehicle.get("identity") or vehicle.get("name"))
        if identity:
            resolved[identity].append(vehicle)
    status = str(source.get("status", "missing"))
    inventory_complete = bool(source.get("inventory_complete", False)) or status in {
        "inventory_complete",
        "fleet_inventory_complete",
        "decoded_inventory_complete",
    }
    return dict(resolved), {
        "status": status,
        "migration_status": source.get("migration_status", "missing"),
        "logical_bytes": int(source.get("logical_bytes", 0) or 0),
        "split_parts": int(source.get("split_parts", 0) or 0),
        "resolved_identities": len(resolved),
        "inventory_complete": inventory_complete,
    }


def collect_rr3_crossmatch(
    evidence: dict[str, Any] | None,
) -> tuple[dict[str, list[dict[str, Any]]], set[str], dict[str, Any]]:
    resolved: dict[str, list[dict[str, Any]]] = defaultdict(list)
    searched: set[str] = set()
    if not evidence:
        return {}, searched, {
            "loaded": False,
            "inventory_complete": False,
            "identities_searched": 0,
            "identities_with_matches": 0,
        }

    for row in evidence.get("candidates", []) or []:
        identity = normalized_identity(row.get("beta1"))
        if not identity:
            continue
        searched.add(identity)
        for source_id in row.get("rr3_matches", []) or []:
            resolved[identity].append(
                {
                    "source_id": source_id,
                    "match_status": row.get("rr3_status"),
                    "recovery": row.get("recovery"),
                    "evidence": evidence.get("checkpoint", "rr3_crossmatch"),
                }
            )

    source_state = evidence.get("source_state", {}) or {}
    inventory_complete = bool(evidence.get("rr3_search_complete", False)) and (
        "547 vehicle directories" in str(source_state.get("rr3", ""))
        or "inventory complete" in str(source_state.get("rr3", "")).lower()
    )
    return dict(resolved), searched, {
        "loaded": True,
        "inventory_complete": inventory_complete,
        "identities_searched": len(searched),
        "identities_with_matches": len(resolved),
    }


def build(
    manifest: dict[str, Any],
    carparking_seed: dict[str, Any] | None = None,
    carparking_evidence: dict[str, Any] | None = None,
    carparking_rights_refresh: dict[str, Any] | None = None,
    rr3_crossmatch: dict[str, Any] | None = None,
    porsche_authorized: bool = True,
) -> dict[str, Any]:
    del porsche_authorized

    beta1 = collect_beta1(manifest)
    car_parking, cp_summary = collect_car_parking(
        manifest,
        carparking_seed,
        carparking_evidence,
        carparking_rights_refresh,
    )
    rr3_manifest, rr3_manifest_summary = collect_rr3_manifest(manifest)
    rr3_match, rr3_searched, rr3_match_summary = collect_rr3_crossmatch(
        rr3_crossmatch
    )

    rr3: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for identity, rows in rr3_manifest.items():
        rr3[identity].extend(rows)
    for identity, rows in rr3_match.items():
        rr3[identity].extend(rows)

    identities = sorted(
        set(beta1) | set(car_parking) | set(rr3),
        key=str.casefold,
    )
    active, deprioritized, excluded = [], [], []

    for identity in identities:
        state = rights_state(identity)
        cp_search_complete = cp_summary["parse_complete"]
        rr3_search_complete = bool(
            identity in rr3_searched
            or rr3_manifest_summary["inventory_complete"]
        )

        row = {
            "identity": identity,
            "rights_status": state,
            "beta1": beta1.get(
                identity, {"status": "exact_identity_not_resolved"}
            ),
            "beta2": {
                "car_parking": car_parking.get(identity, []),
                "real_racing_3": rr3.get(identity, []),
                "car_parking_search_complete": cp_search_complete,
                "car_parking_exact_match": bool(car_parking.get(identity)),
                "real_racing_3_search_complete": rr3_search_complete,
                "real_racing_3_exact_or_candidate_match": bool(rr3.get(identity)),
            },
        }

        if state == "deprioritized_reference_crown007":
            row[
                "promotion_status"
            ] = "accepted_current_state_detail_improvements_continue"
            row["remaining_work"] = (
                "shared fleet improvements may apply later without blocking fleet expansion"
            )
            deprioritized.append(row)
            continue

        searches_complete = cp_search_complete and rr3_search_complete
        row["promotion_status"] = (
            "component_selection_ready"
            if searches_complete
            else "continue_beta2_source_search"
        )
        active.append(row)

    return {
        "format_version": 9,
        "policy": {
            "scope": "full_fleet_parallel_source_fusion",
            "source_use_policy": "godot/docs/vehicle_production/source-use-policy-001.json",
            "brand_filter": "none",
            "porsche": "active_when_present_in_owner_authorized_project_sources",
            "tesla": "active_when_present_in_owner_authorized_project_sources",
            "source_game_maps_world_geography": "excluded",
            "outside_third_party_assets": "require_explicit_owner_approval",
            "quantity": "no_artificial_fleet_cap_quality_gate_still_required",
            "crown007": "accepted_current_state_deprioritized_not_complete",
            "promotion_rule": (
                "Search Beta1 and both Beta2 vehicle sources for every active vehicle. "
                "Track inventory completion separately from per-identity matching. Record "
                "verified no-match evidence; never fabricate an identity from an unrelated donor. "
                "Exact identity/generation/trim compatibility remains mandatory for body promotion."
            ),
        },
        "summary": {
            "active_identities": len(active),
            "deprioritized_reference_identities": len(deprioritized),
            "excluded_identities": len(excluded),
            "beta1_resolved_identities": len(beta1),
            "car_parking": cp_summary,
            "car_parking_seed_loaded": bool(carparking_seed),
            "car_parking_bundle_evidence_loaded": bool(carparking_evidence),
            "car_parking_rights_refresh_loaded": bool(carparking_rights_refresh),
            "real_racing_3": {
                "manifest": rr3_manifest_summary,
                "crossmatch": rr3_match_summary,
            },
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
    parser.add_argument("--carparking-rights-refresh", type=Path)
    parser.add_argument("--rr3-crossmatch", type=Path)
    parser.add_argument(
        "--porsche-authorized",
        action="store_true",
        help="legacy compatibility flag; current source-use policy has no brand filter",
    )
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    manifest = json.loads(args.migration_manifest.read_text(encoding="utf-8"))
    seed = (
        json.loads(args.carparking_seed.read_text(encoding="utf-8"))
        if args.carparking_seed
        else None
    )
    evidence = (
        json.loads(args.carparking_evidence.read_text(encoding="utf-8"))
        if args.carparking_evidence
        else None
    )
    rights_refresh = (
        json.loads(args.carparking_rights_refresh.read_text(encoding="utf-8"))
        if args.carparking_rights_refresh
        else None
    )
    rr3 = (
        json.loads(args.rr3_crossmatch.read_text(encoding="utf-8"))
        if args.rr3_crossmatch
        else None
    )

    result = build(
        manifest,
        seed,
        evidence,
        rights_refresh,
        rr3,
        args.porsche_authorized,
    )
    text = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
    print(text, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
