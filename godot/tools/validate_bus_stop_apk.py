#!/usr/bin/env python3
"""Verify the tested Jamaica bus-stop authority dataset is packaged intact."""
from __future__ import annotations

import argparse
import json
import math
import zipfile
from pathlib import Path

PURPOSE = "visual-only explicit OSM bus-stop point authority; OSM remains geographic authority"
PLACEMENT_RULE = "explicit highway=bus_stop nodes or public_transport=platform nodes with bus=yes only; no inferred stops, shelters or benches"
SHELTER_RULE = "shelter art requires source shelter=yes/true/1/designated; unspecified stops remain unsheltered"
APK_ROOT = "assets/data/roads/bus_stops/"
VALID_KINDS = {"highway=bus_stop", "public_transport=platform+bus"}


def validate(apk: Path, source_manifest: Path) -> dict:
    expected = json.loads(source_manifest.read_text(encoding="utf-8"))
    if expected.get("purpose") != PURPOSE:
        raise ValueError("Bus-stop source lost its geographic authority boundary")
    if expected.get("placement_rule") != PLACEMENT_RULE:
        raise ValueError("Bus-stop source lost its explicit-only placement rule")
    if expected.get("shelter_rule") != SHELTER_RULE:
        raise ValueError("Bus-stop source lost its strict shelter rule")
    if expected.get("crs") != "EPSG:3448":
        raise ValueError("Bus-stop source is not in canonical Jamaica Metric Grid")

    expected_tiles = expected.get("tiles", [])
    stats = expected.get("stats", {})
    expected_features = int(stats.get("features", -1))
    if expected_features < 0 or int(stats.get("tiles", -1)) != len(expected_tiles):
        raise ValueError("Bus-stop manifest statistics are inconsistent")

    source_root = source_manifest.parent
    seen_nodes: set[str] = set()
    shelter_yes = 0
    bench_yes = 0
    with zipfile.ZipFile(apk) as archive:
        corrupt = archive.testzip()
        if corrupt:
            raise ValueError("Corrupt APK entry: " + corrupt)
        names = set(archive.namelist())
        manifest_name = APK_ROOT + "manifest.json"
        if manifest_name not in names:
            raise ValueError("Packaged Jamaica bus-stop manifest is missing")
        packaged = json.loads(archive.read(manifest_name))
        if packaged != expected:
            raise ValueError("Packaged bus-stop manifest differs from tested source")

        for tile in expected_tiles:
            filename = str(tile.get("file", ""))
            source_path = source_root / filename
            apk_name = APK_ROOT + filename
            if not source_path.is_file():
                raise ValueError("Bus-stop source tile is missing: " + filename)
            if apk_name not in names:
                raise ValueError("Bus-stop tile was omitted from APK: " + filename)
            expected_tile = json.loads(source_path.read_text(encoding="utf-8"))
            actual_tile = json.loads(archive.read(apk_name))
            if actual_tile != expected_tile:
                raise ValueError("Packaged bus-stop tile differs from source: " + filename)
            if actual_tile.get("tile") != [tile.get("x"), tile.get("z")]:
                raise ValueError("Bus-stop tile coordinates disagree with manifest: " + filename)
            records = actual_tile.get("bus_stops", [])
            if len(records) != int(tile.get("records", -1)):
                raise ValueError("Bus-stop tile record count disagrees with manifest: " + filename)
            for record in records:
                source_node = str(record.get("source_node", ""))
                position = record.get("position", [])
                kind = str(record.get("kind", ""))
                if not source_node or source_node in seen_nodes:
                    raise ValueError("Bus-stop source identity missing or duplicated: " + source_node)
                if kind not in VALID_KINDS:
                    raise ValueError("Non-bus-stop record entered bus-stop authority: " + source_node)
                if len(position) != 2 or not all(math.isfinite(float(v)) for v in position):
                    raise ValueError("Invalid bus-stop world position: " + source_node)
                seen_nodes.add(source_node)
                if str(record.get("shelter", "unspecified")).lower() in {"yes", "true", "1", "designated"}:
                    shelter_yes += 1
                if str(record.get("bench", "unspecified")).lower() in {"yes", "true", "1", "designated"}:
                    bench_yes += 1

    if len(seen_nodes) != expected_features:
        raise ValueError(f"Bus-stop feature count mismatch: packaged {len(seen_nodes)}, manifest {expected_features}")
    return {
        "features": len(seen_nodes),
        "tiles": len(expected_tiles),
        "shelter_yes": shelter_yes,
        "bench_yes": bench_yes,
        "source_sha256": expected.get("source_sha256"),
        "authority": "explicit OSM bus-stop point nodes only",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    parser.add_argument("manifest", type=Path)
    args = parser.parse_args()
    print("YARDMAN_BUS_STOP_APK_PASS", json.dumps(validate(args.apk, args.manifest), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
