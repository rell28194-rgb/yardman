#!/usr/bin/env python3
"""Compile OSM-tagged Jamaica roadwork geometry into a visual-only tile layer.

This dataset is deliberately separate from the drivable road graph. A way tagged
``highway=construction`` (or an otherwise drivable way carrying a meaningful
``construction`` tag) may drive work-zone visuals, but it cannot become a
navigable Yardman road merely because a recovered cone asset exists.

The CLI also compiles sibling registered fence and drainage sidecars. Keeping
optional road-furniture/engineering evidence on the same packaging invocation
prevents Android builds from silently shipping runtimes without Jamaica metadata.
The datasets remain logically and geographically independent.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import shutil
from collections import Counter, defaultdict
from pathlib import Path

from pyproj import Transformer

from build_drainage import write_dataset as write_drainage_dataset
from build_fences import write_dataset as write_fence_dataset
from build_jamaica_roads import CRS_SOURCE, CRS_TARGET, ORIGIN_LAT, ORIGIN_LON, ROAD_WIDTHS
from road_graph import read_osm_features, road_dimensions, split_segment

FALSE_VALUES = {"", "no", "0", "false", "none", "finished", "complete"}


def _meaningful(value) -> bool:
    return str(value or "").strip().lower() not in FALSE_VALUES


def _is_roadwork(tags: dict) -> bool:
    highway = str(tags.get("highway", "")).strip().lower()
    return highway == "construction" or _meaningful(tags.get("construction"))


def _effective_class(tags: dict) -> str:
    highway = str(tags.get("highway", "road")).strip().lower()
    construction = str(tags.get("construction", "")).strip().lower()
    if highway == "construction":
        return construction if construction in ROAD_WIDTHS else "road"
    return highway if highway in ROAD_WIDTHS else (construction if construction in ROAD_WIDTHS else "road")


def _hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def extract_roadworks(features, transformer, origin, tile_size: float) -> dict:
    if tile_size <= 0 or not math.isfinite(tile_size):
        raise ValueError("tile_size must be finite and positive")
    tiles = defaultdict(list)
    by_type = Counter()
    feature_ids = set()
    source_segments = 0
    tile_pieces = 0
    bounds = [float("inf"), float("inf"), float("-inf"), float("-inf")]

    for feature in features:
        tags = dict(feature.get("properties") or {})
        if isinstance(tags.get("tags"), dict):
            tags.update(tags["tags"])
        if not _is_roadwork(tags):
            continue
        geometry = feature.get("geometry") or {}
        lines = ([geometry.get("coordinates", [])] if geometry.get("type") == "LineString"
                 else geometry.get("coordinates", []) if geometry.get("type") == "MultiLineString" else [])
        source_id = str(feature.get("id") or tags.get("@id") or "")
        if not source_id:
            source_id = "roadwork-" + hashlib.sha1(repr((lines, sorted(tags.items()))).encode()).hexdigest()[:20]
        road_class = _effective_class(tags)
        fallback_width = ROAD_WIDTHS.get(road_class, ROAD_WIDTHS["road"])
        dimension_tags = dict(tags)
        dimension_tags["highway"] = road_class
        width, lanes, width_source = road_dimensions(dimension_tags, fallback_width)
        construction_tag = str(tags.get("construction", "construction" if tags.get("highway") == "construction" else "yes"))
        had_segment = False

        for line_index, line in enumerate(lines):
            if len(line) < 2:
                continue
            points = []
            for coordinate in line:
                e, n = transformer.transform(float(coordinate[0]), float(coordinate[1]))
                point = (round(e - origin[0], 3), 0.0, round(origin[1] - n, 3))
                if not all(math.isfinite(value) for value in point):
                    raise ValueError(f"Non-finite roadwork coordinate in {source_id}")
                points.append(point)
                bounds[0] = min(bounds[0], point[0]); bounds[1] = min(bounds[1], point[2])
                bounds[2] = max(bounds[2], point[0]); bounds[3] = max(bounds[3], point[2])
            for segment_index, (a, b) in enumerate(zip(points, points[1:])):
                if math.dist(a, b) < 0.001:
                    continue
                source_segments += 1
                had_segment = True
                for (tx, tz), start, end in split_segment(a, b, tile_size):
                    tiles[(tx, tz)].append({
                        "source_way": source_id,
                        "line": line_index,
                        "segment": segment_index,
                        "class": road_class,
                        "construction": construction_tag,
                        "start": [round(start[0], 3), round(start[2], 3)],
                        "end": [round(end[0], 3), round(end[2], 3)],
                        "width_m": round(width, 3),
                        "lanes": lanes,
                        "width_source": width_source,
                        "layer": str(tags.get("layer", "0")),
                    })
                    tile_pieces += 1
        if had_segment:
            feature_ids.add(source_id)
            by_type[road_class] += 1

    if not feature_ids:
        bounds = []
    for records in tiles.values():
        records.sort(key=lambda item: (item["source_way"], item["line"], item["segment"], item["start"]))
    return {
        "tiles": dict(tiles),
        "stats": {
            "features": len(feature_ids),
            "source_segments": source_segments,
            "tile_pieces": tile_pieces,
            "tiles": len(tiles),
            "by_effective_class": dict(sorted(by_type.items())),
        },
        "bounds": [round(value, 3) for value in bounds] if bounds else [],
    }


def write_dataset(input_path: Path, output_dir: Path, tile_size: float) -> dict:
    features = read_osm_features(input_path) if input_path.suffix == ".pbf" else json.loads(input_path.read_text(encoding="utf-8")).get("features", [])
    transformer = Transformer.from_crs(CRS_SOURCE, CRS_TARGET, always_xy=True)
    origin_e, origin_n = transformer.transform(ORIGIN_LON, ORIGIN_LAT)
    result = extract_roadworks(features, transformer, (origin_e, origin_n), tile_size)
    staging = output_dir.with_name(output_dir.name + ".staging")
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    tile_entries = []
    for (tx, tz), records in sorted(result["tiles"].items()):
        filename = f"tile_{tx}_{tz}.json"
        (staging / filename).write_text(json.dumps({"tile": [tx, tz], "roadworks": records}, separators=(",", ":")), encoding="utf-8")
        tile_entries.append({"x": tx, "z": tz, "file": filename, "records": len(records)})
    manifest = {
        "format": 1,
        "purpose": "visual-only OSM-tagged roadworks; never navigation authority",
        "source": "OpenStreetMap / Geofabrik Jamaica extract",
        "source_sha256": _hash_file(input_path),
        "attribution": "© OpenStreetMap contributors — https://www.openstreetmap.org/copyright (ODbL)",
        "crs": CRS_TARGET,
        "axis": "X=east, Z=south, metres",
        "tile_size": tile_size,
        "bounds": result["bounds"],
        "stats": result["stats"],
        "tiles": tile_entries,
    }
    (staging / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True), encoding="utf-8")
    if output_dir.exists():
        shutil.rmtree(output_dir)
    staging.replace(output_dir)
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("--tile-size", type=float, default=4096.0)
    args = parser.parse_args()
    manifest = write_dataset(args.input, args.output_dir, args.tile_size)
    fence_manifest = write_fence_dataset(args.input, args.output_dir.parent / "fences", args.tile_size)
    drainage_manifest = write_drainage_dataset(args.input, args.output_dir.parent / "drainage", args.tile_size)
    stats = manifest["stats"]
    fence_stats = fence_manifest["stats"]
    drainage_stats = drainage_manifest["stats"]
    print("YARDMAN_ROADWORKS_BUILD PASS features=%d source_segments=%d tile_pieces=%d tiles=%d" %
          (stats["features"], stats["source_segments"], stats["tile_pieces"], stats["tiles"]))
    print("YARDMAN_FENCES_SIDECAR PASS features=%d wire=%d source_segments=%d tile_pieces=%d tiles=%d" %
          (fence_stats["features"], fence_stats["wire_compatible_features"], fence_stats["source_segments"], fence_stats["tile_pieces"], fence_stats["tiles"]))
    print("YARDMAN_DRAINAGE_SIDECAR PASS features=%d culverts=%d ditches=%d drains=%d tile_pieces=%d tiles=%d" %
          (drainage_stats["features"], drainage_stats["by_kind"].get("culvert", 0),
           drainage_stats["by_kind"].get("ditch", 0), drainage_stats["by_kind"].get("drain", 0),
           drainage_stats["tile_pieces"], drainage_stats["tiles"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
