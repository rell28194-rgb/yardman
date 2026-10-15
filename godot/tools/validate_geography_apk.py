#!/usr/bin/env python3
"""Validate that an Android export preserves Yardman's national place/parish truth."""
from __future__ import annotations

import argparse
import json
import math
from collections import Counter
import zipfile
from pathlib import Path

CANONICAL_PARISHES = {
    "Kingston", "St. Andrew", "St. Catherine", "Clarendon", "Manchester",
    "St. Elizabeth", "Westmoreland", "Hanover", "St. James", "Trelawny",
    "St. Ann", "St. Mary", "Portland", "St. Thomas",
}


def _read_json(archive: zipfile.ZipFile, name: str) -> dict:
    try:
        raw = archive.read(name)
    except KeyError as exc:
        raise ValueError("Missing APK geography resource: " + name) from exc
    try:
        payload = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError("Invalid APK geography JSON: " + name) from exc
    if not isinstance(payload, dict):
        raise ValueError("APK geography resource is not an object: " + name)
    return payload


def _validate_coordinates(record: dict, label: str) -> None:
    if not isinstance(record, dict):
        raise ValueError(label + " is not an object")
    for axis in ("x", "z"):
        value = record.get(axis)
        if (isinstance(value, bool) or not isinstance(value, (int, float))
                or not math.isfinite(value)):
            raise ValueError(label + " has invalid finite coordinate: " + axis)


def validate(apk: Path, road_manifest_path: Path, places_manifest_path: Path,
             parishes_manifest_path: Path) -> dict:
    roads = json.loads(road_manifest_path.read_text(encoding="utf-8"))
    expected_places = json.loads(places_manifest_path.read_text(encoding="utf-8"))
    expected_parishes = json.loads(parishes_manifest_path.read_text(encoding="utf-8"))

    with zipfile.ZipFile(apk) as archive:
        name_counts = Counter(archive.namelist())
        names = set(name_counts)
        for name, count in name_counts.items():
            if count > 1 and name.startswith(("assets/data/places/", "assets/data/parishes/", "assets/data/roads/")):
                raise ValueError("Duplicate ZIP geography authority entry: " + name)
        places = _read_json(archive, "assets/data/places/manifest.json")
        parishes = _read_json(archive, "assets/data/parishes/manifest.json")

        if places != expected_places:
            raise ValueError("Packaged place manifest differs from compiled Jamaica source")
        if parishes != expected_parishes:
            raise ValueError("Packaged parish manifest differs from compiled Jamaica source")

        road_sha = str(roads.get("source_sha256", ""))
        road_crs = str(roads.get("crs", ""))
        if not road_sha or places.get("source_sha256") != road_sha or parishes.get("source_sha256") != road_sha:
            raise ValueError("Road/place/parish source registration differs")
        if road_crs != "EPSG:3448" or places.get("crs") != road_crs or parishes.get("crs") != road_crs:
            raise ValueError("Road/place/parish CRS registration must be EPSG:3448")

        parish_keys = set(parishes.get("parishes", {}))
        if parish_keys != CANONICAL_PARISHES:
            missing = sorted(CANONICAL_PARISHES - parish_keys)
            extra = sorted(parish_keys - CANONICAL_PARISHES)
            raise ValueError("Packaged parish set is not canonical: missing=%r extra=%r" % (missing, extra))
        if int(parishes.get("stats", {}).get("canonical_parishes", -1)) != 14:
            raise ValueError("Parish manifest does not certify all fourteen canonical parishes")
        if parishes.get("stats", {}).get("missing_parishes") not in ([], None):
            raise ValueError("Parish manifest reports missing authoritative geometry")

        stats = places.get("stats", {})
        by_parish = stats.get("by_parish", {})
        if not isinstance(by_parish, dict) or set(by_parish) != CANONICAL_PARISHES:
            raise ValueError("Place manifest does not cover exactly all fourteen parishes")
        if any(int(by_parish.get(parish, 0)) <= 0 for parish in CANONICAL_PARISHES):
            raise ValueError("At least one parish has no packaged named-place coverage")

        capitals = places.get("parish_capitals", {})
        if not isinstance(capitals, dict) or set(capitals) != CANONICAL_PARISHES:
            raise ValueError("Place manifest omitted canonical parish-capital anchors")

        for parish, capital in capitals.items():
            _validate_coordinates(capital, "Parish capital " + parish)

        tiles = places.get("tiles", {})
        if not isinstance(tiles, dict) or int(stats.get("tiles", -1)) != len(tiles):
            raise ValueError("Place tile statistics are inconsistent")
        counted_places = 0
        actual_by_parish = Counter()
        for tile_key, records in tiles.items():
            if not isinstance(records, list):
                raise ValueError("Place tile is not a record list: " + str(tile_key))
            counted_places += len(records)
            for record in records:
                if not isinstance(record, dict):
                    raise ValueError("Place tile contains a non-object record: " + str(tile_key))
                parish = str(record.get("parish", ""))
                if parish not in CANONICAL_PARISHES:
                    raise ValueError("Place record has non-canonical parish: " + repr(parish))
                actual_by_parish[parish] += 1
                _validate_coordinates(record, "Place record in tile " + str(tile_key))
                if not str(record.get("name", "")).strip():
                    raise ValueError("Place record has no name in tile " + str(tile_key))
        if dict(actual_by_parish) != by_parish:
            raise ValueError("Actual per-parish place counts differ from manifest statistics")
        if counted_places != int(stats.get("places", -1)):
            raise ValueError("Packaged place count differs from manifest statistics")

        # Place tiles are embedded in the manifest by design. Parish geometry is
        # likewise manifest-contained. Ensure there is no stale duplicate payload
        # family silently packaged under a second authority path.
        stale_place_payloads = [
            name for name in names
            if name.startswith("assets/data/places/") and name != "assets/data/places/manifest.json"
        ]
        stale_parish_payloads = [
            name for name in names
            if name.startswith("assets/data/parishes/") and name != "assets/data/parishes/manifest.json"
        ]
        if stale_place_payloads or stale_parish_payloads:
            raise ValueError("Unexpected duplicate geography payloads in APK")

    return {
        "parishes": 14,
        "places": counted_places,
        "place_tiles": len(tiles),
        "source_sha256": road_sha,
        "crs": road_crs,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("apk", type=Path)
    parser.add_argument("road_manifest", type=Path)
    parser.add_argument("places_manifest", type=Path)
    parser.add_argument("parishes_manifest", type=Path)
    args = parser.parse_args()
    proof = validate(args.apk, args.road_manifest, args.places_manifest, args.parishes_manifest)
    print("YARDMAN_GEOGRAPHY_APK_PASS", json.dumps(proof, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
