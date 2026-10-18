#!/usr/bin/env python3
"""Validate packaged national authority that ordinary APK structure checks can miss."""
from __future__ import annotations

import argparse
import hashlib
import json
import zipfile
from pathlib import Path

FORBIDDEN_RUNTIME_ASSIGNMENTS = {"nearest_capital_fallback", "canonical_capital_fallback"}


def _read_json(archive: zipfile.ZipFile, name: str) -> dict:
    try:
        return json.loads(archive.read(name))
    except KeyError as exc:
        raise ValueError("Missing APK authority resource: " + name) from exc


def _assert_source_registration(label: str, payload: dict, roads: dict) -> None:
    if payload.get("crs") != roads.get("crs"):
        raise ValueError(f"{label} CRS differs from roads")
    if payload.get("source_sha256") != roads.get("source_sha256"):
        raise ValueError(f"{label} source hash differs from roads")
    origin = payload.get("origin", {})
    road_origin = roads.get("origin", {})
    if origin.get("easting") != road_origin.get("easting") or origin.get("northing") != road_origin.get("northing"):
        raise ValueError(f"{label} origin differs from roads")


def validate(apk: Path, roads_manifest: Path, places_manifest: Path, parishes_manifest: Path) -> dict:
    roads_expected = json.loads(roads_manifest.read_text())
    places_expected = json.loads(places_manifest.read_text())
    parishes_expected = json.loads(parishes_manifest.read_text())

    with zipfile.ZipFile(apk) as archive:
        names = set(archive.namelist())
        roads = _read_json(archive, "assets/data/roads/manifest.json")
        places = _read_json(archive, "assets/data/places/manifest.json")
        parishes = _read_json(archive, "assets/data/parishes/manifest.json")
        if roads != roads_expected:
            raise ValueError("Packaged road manifest differs from compiled source")
        if places != places_expected:
            raise ValueError("Packaged place authority differs from compiled source")
        if parishes != parishes_expected:
            raise ValueError("Packaged parish authority differs from compiled source")

        _assert_source_registration("Place authority", places, roads)
        _assert_source_registration("Parish authority", parishes, roads)

        parish_stats = parishes.get("stats", {})
        parish_records = parishes.get("parishes", {})
        if not isinstance(parish_records, dict) or len(parish_records) != 14:
            raise ValueError("Packaged parish authority does not contain fourteen parishes")
        if int(parish_stats.get("canonical_parishes", -1)) != 14:
            raise ValueError("Packaged parish authority canonical count is not fourteen")
        if parish_stats.get("missing_parishes"):
            raise ValueError("Packaged parish authority reports missing parishes")

        runtime_place_count = 0
        for tile_key, records in places.get("tiles", {}).items():
            if not isinstance(records, list):
                raise ValueError("Packaged place tile is not a list: " + str(tile_key))
            for record in records:
                if not isinstance(record, dict):
                    raise ValueError("Packaged place tile contains an invalid record: " + str(tile_key))
                parish = str(record.get("parish", ""))
                assignment = str(record.get("parish_assignment", ""))
                source = str(record.get("source", ""))
                if not parish:
                    raise ValueError("Runtime place record has unresolved parish authority: " + source)
                if assignment in FORBIDDEN_RUNTIME_ASSIGNMENTS:
                    raise ValueError("Runtime place record retained guessed parish assignment: " + source)
                if source.startswith("fallback/"):
                    raise ValueError("Runtime place record is synthetic: " + source)
                runtime_place_count += 1
        if runtime_place_count != int(places.get("stats", {}).get("places", -1)):
            raise ValueError("Packaged place count differs from manifest statistics")

        graph = roads.get("graph", {})
        route = graph.get("route_pack", {}) if isinstance(graph, dict) else {}
        filename = str(route.get("file", ""))
        route_name = "assets/data/roads/graph/" + filename
        if not filename or route_name not in names:
            raise ValueError("Native route pack is missing from APK")
        route_bytes = archive.read(route_name)
        if hashlib.sha256(route_bytes).hexdigest() != str(route.get("sha256", "")):
            raise ValueError("Packaged native route pack SHA differs from road manifest")
        if len(route_bytes) < 32 or route_bytes[:4] != b"YMR1":
            raise ValueError("Packaged native route pack header is invalid")
        if int(route.get("nodes", -1)) != int(graph.get("nodes", -2)):
            raise ValueError("Native route-pack node count differs from graph manifest")
        if int(route.get("edges", -1)) != int(graph.get("edges", -2)):
            raise ValueError("Native route-pack edge count differs from graph manifest")

    return {
        "route_pack_bytes": len(route_bytes),
        "route_pack_sha256": hashlib.sha256(route_bytes).hexdigest(),
        "runtime_places": runtime_place_count,
        "parishes": len(parish_records),
        "unresolved_place_records": int(places.get("stats", {}).get("unresolved_source_records", 0)),
        "dropped_synthetic_places": int(places.get("stats", {}).get("dropped_synthetic_records", 0)),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    parser.add_argument("roads_manifest", type=Path)
    parser.add_argument("places_manifest", type=Path)
    parser.add_argument("parishes_manifest", type=Path)
    args = parser.parse_args()
    proof = validate(args.apk, args.roads_manifest, args.places_manifest, args.parishes_manifest)
    print("YARDMAN_PACKAGED_AUTHORITY_PASS", json.dumps(proof, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
