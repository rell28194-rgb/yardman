#!/usr/bin/env python3
"""Verify the tested Jamaica fence authority dataset is packaged intact."""
from __future__ import annotations

import argparse
import json
import math
import zipfile
from pathlib import Path

PURPOSE = "visual-only OSM barrier=fence geometry; OSM remains geographic authority"
WIRE_RULE = "explicit chain-link/wire/metal/steel/barbed-wire tags only; untyped fences are not assigned recovered chain-link art"
APK_ROOT = "assets/data/roads/fences/"


def validate(apk: Path, source_manifest: Path) -> dict:
    expected = json.loads(source_manifest.read_text(encoding="utf-8"))
    if expected.get("purpose") != PURPOSE:
        raise ValueError("Fence source lost its geographic authority boundary")
    if expected.get("wire_compatibility_rule") != WIRE_RULE:
        raise ValueError("Fence source lost its strict wire-compatibility rule")
    if expected.get("crs") != "EPSG:3448":
        raise ValueError("Fence source is not in canonical Jamaica Metric Grid")

    expected_tiles = expected.get("tiles", [])
    stats = expected.get("stats", {})
    expected_features = int(stats.get("features", -1))
    expected_wire = int(stats.get("wire_compatible_features", -1))
    expected_pieces = int(stats.get("tile_pieces", -1))
    if expected_features < 0 or expected_wire < 0 or expected_pieces < 0:
        raise ValueError("Fence manifest has invalid statistics")
    if expected_wire > expected_features or int(stats.get("tiles", -1)) != len(expected_tiles):
        raise ValueError("Fence manifest statistics are inconsistent")

    source_root = source_manifest.parent
    counted_pieces = 0
    seen_features: set[str] = set()
    seen_wire_features: set[str] = set()
    with zipfile.ZipFile(apk) as archive:
        corrupt = archive.testzip()
        if corrupt:
            raise ValueError("Corrupt APK entry: " + corrupt)
        names = set(archive.namelist())
        manifest_name = APK_ROOT + "manifest.json"
        if manifest_name not in names:
            raise ValueError("Packaged Jamaica fence manifest is missing")
        packaged = json.loads(archive.read(manifest_name))
        if packaged != expected:
            raise ValueError("Packaged fence manifest differs from tested source")

        for tile in expected_tiles:
            filename = str(tile.get("file", ""))
            source_path = source_root / filename
            apk_name = APK_ROOT + filename
            if not source_path.is_file():
                raise ValueError("Fence source tile is missing: " + filename)
            if apk_name not in names:
                raise ValueError("Fence tile was omitted from APK: " + filename)
            expected_tile = json.loads(source_path.read_text(encoding="utf-8"))
            actual_tile = json.loads(archive.read(apk_name))
            if actual_tile != expected_tile:
                raise ValueError("Packaged fence tile differs from source: " + filename)
            if actual_tile.get("tile") != [tile.get("x"), tile.get("z")]:
                raise ValueError("Fence tile coordinates disagree with manifest: " + filename)
            records = actual_tile.get("fences", [])
            if len(records) != int(tile.get("records", -1)):
                raise ValueError("Fence tile record count disagrees with manifest: " + filename)
            for record in records:
                source_way = str(record.get("source_way", ""))
                start = record.get("start", [])
                end = record.get("end", [])
                if not source_way:
                    raise ValueError("Fence record lost source way identity")
                if record.get("barrier") != "fence":
                    raise ValueError("Non-fence record entered fence authority: " + source_way)
                if len(start) != 2 or len(end) != 2 or not all(math.isfinite(float(v)) for v in [*start, *end]):
                    raise ValueError("Invalid fence world geometry: " + source_way)
                wire = record.get("wire_compatible")
                if not isinstance(wire, bool):
                    raise ValueError("Fence wire compatibility is not explicit boolean: " + source_way)
                seen_features.add(source_way)
                if wire:
                    seen_wire_features.add(source_way)
                counted_pieces += 1

    if counted_pieces != expected_pieces:
        raise ValueError(f"Fence tile-piece count mismatch: packaged {counted_pieces}, manifest {expected_pieces}")
    if len(seen_features) != expected_features:
        raise ValueError(f"Fence feature count mismatch: packaged {len(seen_features)}, manifest {expected_features}")
    if len(seen_wire_features) != expected_wire:
        raise ValueError(f"Fence wire-compatible count mismatch: packaged {len(seen_wire_features)}, manifest {expected_wire}")
    return {
        "features": len(seen_features),
        "wire_compatible_features": len(seen_wire_features),
        "tile_pieces": counted_pieces,
        "tiles": len(expected_tiles),
        "source_sha256": expected.get("source_sha256"),
        "authority": "explicit barrier=fence only",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    parser.add_argument("manifest", type=Path)
    args = parser.parse_args()
    print("YARDMAN_FENCE_APK_PASS", json.dumps(validate(args.apk, args.manifest), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
