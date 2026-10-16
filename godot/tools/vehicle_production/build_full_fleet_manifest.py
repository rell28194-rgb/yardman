#!/usr/bin/env python3
"""Build Yardman's full-fleet migration manifest from private source inventories.

No private media is embedded. The tool inventories every recoverable CarX vehicle
root and every Car Parking Multiplayer car-number bundle. RR3 is represented as a
source-wide queue until its per-car inventory is decoded. Porsche remains a hard
promotion/extraction exclusion unless owner rights change.
"""
from __future__ import annotations

import argparse
import collections
import gzip
import json
import re
from pathlib import Path

WHEELS = {"WheelFL", "WheelFR", "WheelRL", "WheelRR"}
BODY_NAMES = {"Body", "BodyH", "BodyL", "Body_H", "Body_L"}
DENIED = re.compile(r"(?i)\bporsche\b|\b911\b|\b992\b|\bcayenne\b|\bpanamera\b|\bmacan\b|\btaycan\b|\bcayman\b|\bboxster\b")
IDENTITY_TOKENS = re.compile(
    r"(?i)^(Toyota[A-Za-z0-9_ -]*|Nissan[A-Za-z0-9_ -]*|BMW[A-Za-z0-9_ -]*|"
    r"Bmw[A-Za-z0-9_ -]*|Mercedes[A-Za-z0-9_ -]*|Mazda[A-Za-z0-9_ -]*|"
    r"Mitsubishi[A-Za-z0-9_ -]*|Subaru[A-Za-z0-9_ -]*|Honda[A-Za-z0-9_ -]*|"
    r"AudiR[A-Za-z0-9_ -]*|Dodge[A-Za-z0-9_ -]*|Lexus[A-Za-z0-9_ -]*|"
    r"Ford[A-Za-z0-9_ -]*|Chevrolet[A-Za-z0-9_ -]*|Mustang[A-Za-z0-9_ -]*|"
    r"Camaro[A-Za-z0-9_ -]*|Silvia[A-Za-z0-9_ -]*|Skyline[A-Za-z0-9_ -]*|AE86|Ae86)"
)


def clean_identity(names: set[str]) -> str | None:
    clues: list[str] = []
    for name in sorted(names):
        match = IDENTITY_TOKENS.search(name)
        if not match:
            continue
        clue = match.group(1).strip(" _-")
        clue = re.sub(
            r"(?i)(?:_?ivent(?:_paint)?|_?livery|_?custom|_?paint|\s*-\s*stoplights|_?halloween.*)$",
            "",
            clue,
        ).strip(" _-")
        if clue:
            clues.append(clue)
    if not clues:
        return None
    return collections.Counter(clues).most_common(1)[0][0]


def carx_manifest(path: Path) -> list[dict]:
    by_file: dict[str, dict] = collections.defaultdict(
        lambda: {"names": set(), "types": collections.Counter(), "records": 0}
    )
    with gzip.open(path, "rt", errors="ignore") as stream:
        for line in stream:
            obj = json.loads(line)
            file_id = obj.get("file")
            if not file_id:
                continue
            entry = by_file[file_id]
            entry["records"] += 1
            entry["types"][obj.get("type", "")] += 1
            name = obj.get("name") or ""
            if name:
                entry["names"].add(name)

    vehicles: list[dict] = []
    for file_id, entry in sorted(by_file.items()):
        names = entry["names"]
        if not (WHEELS <= names and (BODY_NAMES & names)):
            continue
        identity = clean_identity(names)
        denied = bool(identity and DENIED.search(identity))
        vehicles.append(
            {
                "source": "carx_drift",
                "source_unit": file_id,
                "identity": identity,
                "identity_status": "resolved_from_source_names" if identity else "unresolved",
                "rights_status": (
                    "excluded_porsche"
                    if denied
                    else ("owner_authorized_non_porsche" if identity else "identity_gate_required")
                ),
                "migration_status": "excluded" if denied else "queued",
                "object_records": entry["records"],
                "body_nodes": sorted(BODY_NAMES & names),
                "has_interior": any(
                    item in names for item in ("InteriorH", "InteriorL", "Interior_H", "Interior_L")
                ),
                "has_engine_node": "Engine" in names,
                "has_camera_points": any(
                    item in names for item in ("WheelCameraPoint", "HoodCameraPoint", "BumperCameraPoint")
                ),
            }
        )
    return vehicles


def car_parking_manifest(path: Path) -> list[dict]:
    data = json.loads(path.read_text(encoding="utf-8"))
    bundles: dict[int, str] = {}
    matcher = re.compile(r"assets/aa/Android/car(\d+)_assets_all_[0-9a-f]+\.bundle$", re.I)

    def walk(value):
        if isinstance(value, dict):
            for child in value.values():
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)
        elif isinstance(value, str):
            match = matcher.search(value)
            if match:
                bundles[int(match.group(1))] = value

    walk(data)
    known = {218: "Toyota Crown 2013"}
    vehicles: list[dict] = []
    for catalog_id, bundle_path in sorted(bundles.items()):
        identity = known.get(catalog_id)
        vehicles.append(
            {
                "source": "car_parking_multiplayer",
                "catalog_id": catalog_id,
                "bundle_path": bundle_path,
                "identity": identity,
                "identity_status": "resolved" if identity else "pending_catalog_decode",
                "rights_status": "owner_authorized_non_porsche" if identity else "identity_gate_required",
                "migration_status": "queued",
            }
        )
    return vehicles


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--carx", type=Path, required=True, help="CarX full object NDJSON.gz")
    parser.add_argument("--car-parking", type=Path, required=True, help="CarParking apk-inventory.json")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    carx = carx_manifest(args.carx)
    car_parking = car_parking_manifest(args.car_parking)
    report = {
        "format_version": 1,
        "policy": {
            "scope": "full_fleet_migration",
            "sources": ["CarX Drift", "Car Parking Multiplayer", "Real Racing 3"],
            "selection": "all recoverable cars; quality/recovery difficulty controls order only",
            "rights_exception": "Porsche excluded; unresolved identities must pass identity gate before model/media extraction or render promotion",
            "runtime_integration": "deferred to main optimization lane",
        },
        "sources": {
            "carx_drift": {
                "root_vehicle_candidates": len(carx),
                "queued": sum(vehicle["migration_status"] == "queued" for vehicle in carx),
                "excluded": sum(vehicle["migration_status"] == "excluded" for vehicle in carx),
                "resolved_identity": sum(vehicle["identity"] is not None for vehicle in carx),
                "vehicles": carx,
            },
            "car_parking_multiplayer": {
                "actual_car_number_bundles": len(car_parking),
                "queued": len(car_parking),
                "resolved_identity": sum(vehicle["identity"] is not None for vehicle in car_parking),
                "vehicles": car_parking,
            },
            "real_racing_3": {
                "source": "com.ea.games.r3_row_xclipse",
                "split_parts": 246,
                "logical_bytes": 6165950862,
                "status": "source_container_confirmed_car_inventory_pending",
                "migration_status": "queue_entire_fleet_after_inventory",
            },
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(
        json.dumps(
            {
                source: {key: value for key, value in state.items() if key != "vehicles"}
                for source, state in report["sources"].items()
            },
            indent=2,
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
