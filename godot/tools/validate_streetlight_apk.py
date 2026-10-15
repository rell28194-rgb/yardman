#!/usr/bin/env python3
"""Verify the tested Jamaica street-light authority dataset is packaged intact."""
from __future__ import annotations

import argparse
import json
import math
import zipfile
from pathlib import Path

from validate_geography_apk import validate as validate_national_geography

PURPOSE = "visual-only explicit OSM highway=street_lamp points; OSM remains geographic authority"
PLACEMENT_RULE = "explicit highway=street_lamp nodes only; no inferred spacing or recovered-art placement"
APK_ROOT = "assets/data/roads/streetlights/"


def validate(apk: Path, source_manifest: Path) -> dict:
    expected = json.loads(source_manifest.read_text(encoding="utf-8"))
    if expected.get("purpose") != PURPOSE:
        raise ValueError("Street-light source lost its geographic authority boundary")
    if expected.get("placement_rule") != PLACEMENT_RULE:
        raise ValueError("Street-light source lost its explicit-only placement rule")
    if expected.get("crs") != "EPSG:3448":
        raise ValueError("Street-light source is not in canonical Jamaica Metric Grid")

    expected_tiles = expected.get("tiles", [])
    expected_records = int(expected.get("stats", {}).get("features", -1))
    if expected_records < 0 or int(expected.get("stats", {}).get("tiles", -1)) != len(expected_tiles):
        raise ValueError("Street-light manifest statistics are inconsistent")

    source_root = source_manifest.parent
    seen_nodes: set[str] = set()
    counted = 0
    with zipfile.ZipFile(apk) as archive:
        corrupt = archive.testzip()
        if corrupt:
            raise ValueError("Corrupt APK entry: " + corrupt)
        names = set(archive.namelist())
        manifest_name = APK_ROOT + "manifest.json"
        if manifest_name not in names:
            raise ValueError("Packaged Jamaica street-light manifest is missing")
        packaged = json.loads(archive.read(manifest_name))
        if packaged != expected:
            raise ValueError("Packaged street-light manifest differs from tested source")
        for tile in expected_tiles:
            filename = str(tile.get("file", ""))
            source_path = source_root / filename
            apk_name = APK_ROOT + filename
            if not source_path.is_file():
                raise ValueError("Street-light source tile is missing: " + filename)
            if apk_name not in names:
                raise ValueError("Street-light tile was omitted from APK: " + filename)
            expected_tile = json.loads(source_path.read_text(encoding="utf-8"))
            actual_tile = json.loads(archive.read(apk_name))
            if actual_tile != expected_tile:
                raise ValueError("Packaged street-light tile differs from source: " + filename)
            if actual_tile.get("tile") != [tile.get("x"), tile.get("z")]:
                raise ValueError("Street-light tile coordinates disagree with manifest: " + filename)
            records = actual_tile.get("street_lights", [])
            if len(records) != int(tile.get("records", -1)):
                raise ValueError("Street-light tile record count disagrees with manifest: " + filename)
            for record in records:
                node = str(record.get("source_node", ""))
                position = record.get("position", [])
                if not node or node in seen_nodes:
                    raise ValueError("Missing or duplicate street-light source node: " + node)
                if len(position) != 2 or not all(math.isfinite(float(v)) for v in position):
                    raise ValueError("Invalid street-light world position: " + node)
                if record.get("highway") != "street_lamp":
                    raise ValueError("Non-street-lamp record entered street-light authority: " + node)
                seen_nodes.add(node)
                counted += 1

    if counted != expected_records:
        raise ValueError(f"Street-light feature count mismatch: packaged {counted}, manifest {expected_records}")

    road_manifest = source_manifest.parent.parent / "manifest.json"
    data_root = road_manifest.parent.parent
    places_manifest = data_root / "places" / "manifest.json"
    parishes_manifest = data_root / "parishes" / "manifest.json"
    geography_proof = None
    if places_manifest.is_file() or parishes_manifest.is_file():
        if not road_manifest.is_file() or not places_manifest.is_file() or not parishes_manifest.is_file():
            raise ValueError("National geography sidecars are only partially present in the compiled source")
        geography_proof = validate_national_geography(apk, road_manifest, places_manifest, parishes_manifest)

    proof = {
        "features": counted,
        "tiles": len(expected_tiles),
        "source_sha256": expected.get("source_sha256"),
        "authority": "explicit highway=street_lamp only",
    }
    if geography_proof is not None:
        proof["national_geography"] = geography_proof
    return proof


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    parser.add_argument("manifest", type=Path)
    args = parser.parse_args()
    print("YARDMAN_STREETLIGHT_APK_PASS", json.dumps(validate(args.apk, args.manifest), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
