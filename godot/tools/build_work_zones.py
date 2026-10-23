#!/usr/bin/env python3
"""Compile OSM highway=construction ways into a non-drivable Yardman sidecar.

This deliberately does not add construction ways to the persistent road graph or
road surface tiles. It only preserves source-backed centreline/width evidence so
presentation systems can place temporary work-zone props without inventing sites.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from collections import defaultdict
from pathlib import Path
from typing import Dict, Iterable, List, Sequence, Tuple

from road_graph import read_osm_features, road_dimensions, split_segment

CRS_SOURCE = "EPSG:4326"
CRS_TARGET = "EPSG:3448"
ORIGIN_LAT = 17.9714
ORIGIN_LON = -76.7936
DEFAULT_TILE_SIZE = 4096.0
DEFAULT_WIDTH_M = 5.8
ROAD_WIDTHS = {
    "motorway": 8.4, "motorway_link": 4.6,
    "trunk": 8.0, "trunk_link": 4.3,
    "primary": 7.2, "primary_link": 4.0,
    "secondary": 6.8, "secondary_link": 3.8,
    "tertiary": 6.4, "tertiary_link": 3.6,
    "unclassified": 5.8, "residential": 5.5,
    "living_street": 4.5, "service": 3.5,
    "road": 5.8, "track": 3.0, "raceway": 8.0,
}


def _tags(feature: dict) -> dict:
    tags = dict(feature.get("properties") or {})
    if isinstance(tags.get("tags"), dict):
        tags.update(tags["tags"])
    return tags


def _lines(feature: dict) -> Iterable[Sequence[Sequence[float]]]:
    geometry = feature.get("geometry") or {}
    if geometry.get("type") == "LineString":
        yield geometry.get("coordinates", [])
    elif geometry.get("type") == "MultiLineString":
        yield from geometry.get("coordinates", [])


def _source_id(feature: dict, tags: dict, lines: list) -> str:
    value = str(feature.get("id") or tags.get("@id") or "")
    if value:
        return value
    signature = repr((lines, sorted(tags.items())))
    return "geojson-" + hashlib.sha1(signature.encode()).hexdigest()[:20]


def compile_work_zones(features: Iterable[dict], transformer, origin: Tuple[float, float],
                       tile_size: float = DEFAULT_TILE_SIZE, height_sampler=None) -> dict:
    if not math.isfinite(tile_size) or tile_size <= 0.0:
        raise ValueError("tile_size must be finite and positive")
    sectors: Dict[Tuple[int, int], List[dict]] = defaultdict(list)
    source_ways = 0
    source_segments = 0
    emitted_segments = 0
    skipped_invalid = 0

    for feature in features:
        tags = _tags(feature)
        if str(tags.get("highway", "")).lower() != "construction":
            continue
        raw_lines = list(_lines(feature))
        if not raw_lines:
            skipped_invalid += 1
            continue
        source_id = _source_id(feature, tags, raw_lines)
        intended = str(tags.get("construction", "road")).lower()
        dimension_class = intended if intended in ROAD_WIDTHS else "road"
        dimension_tags = dict(tags)
        dimension_tags["highway"] = dimension_class
        width, lanes, width_source = road_dimensions(
            dimension_tags, ROAD_WIDTHS.get(dimension_class, DEFAULT_WIDTH_M))
        way_emitted = False

        for line_index, line in enumerate(raw_lines):
            if len(line) < 2:
                skipped_invalid += 1
                continue
            points = []
            for coordinate in line:
                if len(coordinate) < 2:
                    continue
                easting, northing = transformer.transform(float(coordinate[0]), float(coordinate[1]))
                x = round(float(easting) - origin[0], 3)
                z = round(origin[1] - float(northing), 3)
                y = round(float(height_sampler(x, z)), 6) if height_sampler else 0.0
                if not all(math.isfinite(v) for v in (x, y, z)):
                    raise ValueError(f"Non-finite construction coordinate in {source_id}")
                points.append((x, y, z))
            if len(points) < 2:
                skipped_invalid += 1
                continue
            for segment_index, (a, b) in enumerate(zip(points, points[1:])):
                if math.dist(a, b) < 0.25:
                    continue
                source_segments += 1
                for (tx, tz), p, q in split_segment(a, b, tile_size):
                    sectors[(tx, tz)].append({
                        "a": [round(float(p[0]), 3), round(float(p[1]), 3), round(float(p[2]), 3)],
                        "b": [round(float(q[0]), 3), round(float(q[1]), 3), round(float(q[2]), 3)],
                        "width_m": round(float(width), 3),
                        "lanes": int(lanes),
                        "width_source": str(width_source),
                        "source_way": source_id,
                        "line_index": int(line_index),
                        "segment_index": int(segment_index),
                        "construction_class": intended,
                        "surface": str(tags.get("surface", "unknown")),
                        "access": str(tags.get("access", "unknown")),
                    })
                    emitted_segments += 1
                    way_emitted = True
        if way_emitted:
            source_ways += 1

    packed = []
    for (tx, tz), records in sorted(sectors.items()):
        records.sort(key=lambda item: (
            item["source_way"], item["line_index"], item["segment_index"],
            item["a"][0], item["a"][2], item["b"][0], item["b"][2]))
        packed.append([tx, tz, records])
    return {
        "format": 1,
        "tile_size": float(tile_size),
        "source_contract": "OpenStreetMap highway=construction only",
        "drivable": False,
        "navigation": False,
        "geographic_authority": True,
        "presentation_use": "temporary work-zone props only",
        "stats": {
            "source_ways": source_ways,
            "source_segments": source_segments,
            "segments": emitted_segments,
            "sectors": len(packed),
            "skipped_invalid": skipped_invalid,
        },
        "sectors": packed,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path, help="Jamaica OSM PBF or GeoJSON")
    parser.add_argument("output", type=Path, help="work_zones.json")
    parser.add_argument("--tile-size", type=float, default=DEFAULT_TILE_SIZE)
    parser.add_argument("--terrain", type=Path, help="Optional compiled terrain root for registered Y")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    from pyproj import Transformer

    if args.input.suffix.lower() == ".pbf":
        features = read_osm_features(args.input)
    else:
        payload = json.loads(args.input.read_text(encoding="utf-8"))
        if payload.get("type") != "FeatureCollection":
            raise ValueError("Expected OSM PBF or GeoJSON FeatureCollection")
        features = payload.get("features", [])
    transformer = Transformer.from_crs(CRS_SOURCE, CRS_TARGET, always_xy=True)
    origin_e, origin_n = transformer.transform(ORIGIN_LON, ORIGIN_LAT)
    sampler = None
    if args.terrain:
        from build_terrain import TerrainSampler
        sampler = TerrainSampler(args.terrain)
    result = compile_work_zones(features, transformer, (origin_e, origin_n), args.tile_size, sampler)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True), encoding="utf-8")
    print(json.dumps(result["stats"], sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
