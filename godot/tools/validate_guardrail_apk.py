#!/usr/bin/env python3
"""Verify the tested Jamaica guard-rail authority dataset is packaged intact."""
from __future__ import annotations

import argparse
import json
import math
import zipfile
from pathlib import Path

PURPOSE = "visual-only explicit OSM barrier=guard_rail geometry; OSM remains geographic authority"
PLACEMENT_RULE = "explicit barrier=guard_rail ways only; no inferred highway-edge or recovered-art placement"
APK_ROOT = "assets/data/roads/guardrails/"


def validate(apk: Path, source_manifest: Path) -> dict:
    expected = json.loads(source_manifest.read_text(encoding="utf-8"))
    if expected.get("purpose") != PURPOSE:
        raise ValueError("Guard-rail source lost its geographic authority boundary")
    if expected.get("placement_rule") != PLACEMENT_RULE:
        raise ValueError("Guard-rail source lost its explicit-only placement rule")
    if expected.get("crs") != "EPSG:3448":
        raise ValueError("Guard-rail source is not in canonical Jamaica Metric Grid")

    expected_tiles = expected.get("tiles", [])
    stats = expected.get("stats", {})
    expected_features = int(stats.get("features", -1))
    expected_pieces = int(stats.get("tile_pieces", -1))
    if expected_features < 0 or expected_pieces < 0 or int(stats.get("tiles", -1)) != len(expected_tiles):
        raise ValueError("Guard-rail manifest statistics are inconsistent")

    source_root = source_manifest.parent
    counted_pieces = 0
    seen_features: set[str] = set()
    with zipfile.ZipFile(apk) as archive:
        corrupt = archive.testzip()
        if corrupt:
            raise ValueError("Corrupt APK entry: " + corrupt)
        names = set(archive.namelist())
        manifest_name = APK_ROOT + "manifest.json"
        if manifest_name not in names:
            raise ValueError("Packaged Jamaica guard-rail manifest is missing")
        packaged = json.loads(archive.read(manifest_name))
        if packaged != expected:
            raise ValueError("Packaged guard-rail manifest differs from tested source")

        for tile in expected_tiles:
            filename = str(tile.get("file", ""))
            source_path = source_root / filename
            apk_name = APK_ROOT + filename
            if not source_path.is_file():
                raise ValueError("Guard-rail source tile is missing: " + filename)
            if apk_name not in names:
                raise ValueError("Guard-rail tile was omitted from APK: " + filename)
            expected_tile = json.loads(source_path.read_text(encoding="utf-8"))
            actual_tile = json.loads(archive.read(apk_name))
            if actual_tile != expected_tile:
                raise ValueError("Packaged guard-rail tile differs from source: " + filename)
            if actual_tile.get("tile") != [tile.get("x"), tile.get("z")]:
                raise ValueError("Guard-rail tile coordinates disagree with manifest: " + filename)
            records = actual_tile.get("guard_rails", [])
            if len(records) != int(tile.get("records", -1)):
                raise ValueError("Guard-rail tile record count disagrees with manifest: " + filename)
            for record in records:
                source_way = str(record.get("source_way", ""))
                start = record.get("start", [])
                end = record.get("end", [])
                if not source_way:
                    raise ValueError("Guard-rail record lost source way identity")
                if record.get("barrier") != "guard_rail":
                    raise ValueError("Non-guard-rail record entered guard-rail authority: " + source_way)
                if len(start) != 2 or len(end) != 2 or not all(math.isfinite(float(v)) for v in [*start, *end]):
                    raise ValueError("Invalid guard-rail world geometry: " + source_way)
                seen_features.add(source_way)
                counted_pieces += 1

    if counted_pieces != expected_pieces:
        raise ValueError(f"Guard-rail tile-piece count mismatch: packaged {counted_pieces}, manifest {expected_pieces}")
    if len(seen_features) != expected_features:
        raise ValueError(f"Guard-rail feature count mismatch: packaged {len(seen_features)}, manifest {expected_features}")
    return {
        "features": len(seen_features),
        "tile_pieces": counted_pieces,
        "tiles": len(expected_tiles),
        "source_sha256": expected.get("source_sha256"),
        "authority": "explicit barrier=guard_rail only",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    parser.add_argument("manifest", type=Path)
    args = parser.parse_args()
    print("YARDMAN_GUARDRAIL_APK_PASS", json.dumps(validate(args.apk, args.manifest), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
