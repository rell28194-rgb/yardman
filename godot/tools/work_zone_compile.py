"""Compile OSM highway=construction lines as non-drivable Yardman work-zone truth.

This module is intentionally separate from road_graph.py. Construction ways are
presentation evidence for active/incomplete road works; they must never become
routing edges, collision ribbons, parish coverage, or ordinary drivable roads.
"""
from __future__ import annotations

import hashlib
import math
from collections import Counter, defaultdict

from road_graph import split_segment


def _feature_tags(feature: dict) -> dict:
    tags = dict(feature.get("properties") or {})
    if isinstance(tags.get("tags"), dict):
        tags.update(tags["tags"])
    return tags


def _feature_lines(feature: dict):
    geometry = feature.get("geometry") or {}
    if geometry.get("type") == "LineString":
        return [geometry.get("coordinates", [])]
    if geometry.get("type") == "MultiLineString":
        return geometry.get("coordinates", [])
    return []


def _source_id(feature: dict, lines, tags) -> str:
    value = str(feature.get("id") or tags.get("@id") or "")
    if value:
        return value
    signature = repr((lines, sorted(tags.items())))
    return "geojson-" + hashlib.sha1(signature.encode()).hexdigest()[:20]


def compile_work_zones(features, transformer, origin, tile_size: float, height_sampler=None) -> dict:
    """Return compact, tile-owned source centreline pieces for road works.

    Input features are the same unfiltered OSM/GeoJSON highway features consumed
    by the drivable compiler. Only ``highway=construction`` is accepted. Each
    output segment preserves the source way ID, construction subtype and exact
    transformed endpoints. DEM elevation is sampled when available.
    """
    if not math.isfinite(tile_size) or tile_size <= 0.0:
        raise ValueError("tile_size must be finite and positive")
    tiles = defaultdict(list)
    by_type = Counter()
    source_ways = 0
    source_segments = 0
    tile_pieces = 0
    for feature in features:
        tags = _feature_tags(feature)
        if str(tags.get("highway", "")).lower() != "construction":
            continue
        lines = _feature_lines(feature)
        source_id = _source_id(feature, lines, tags)
        subtype = str(tags.get("construction", "unknown") or "unknown").lower()
        access = str(tags.get("access", "") or "").lower()
        for line_index, line in enumerate(lines):
            if len(line) < 2:
                continue
            points = []
            for coordinate in line:
                easting, northing = transformer.transform(float(coordinate[0]), float(coordinate[1]))
                x = round(easting - origin[0], 3)
                z = round(origin[1] - northing, 3)
                y = round(float(height_sampler(x, z)), 6) if height_sampler else 0.0
                if not all(math.isfinite(value) for value in (x, y, z)):
                    raise ValueError(f"Non-finite construction coordinate in {source_id}")
                points.append((x, y, z))
            accepted_way = False
            for segment_index, (a, b) in enumerate(zip(points, points[1:])):
                if math.dist(a, b) < 0.25:
                    continue
                source_segments += 1
                for (tx, tz), p, q in split_segment(a, b, tile_size):
                    length = math.dist(p, q)
                    if length < 0.25:
                        continue
                    record = {
                        "id": f"{source_id}:{line_index}:{segment_index}",
                        "source_way": source_id,
                        "construction": subtype,
                        "access": access,
                        "a": [round(float(v), 3) for v in p],
                        "b": [round(float(v), 3) for v in q],
                        "length_m": round(length, 3),
                        "elevation_source": "DEM" if height_sampler else "unmeasured-flat",
                    }
                    tiles[(tx, tz)].append(record)
                    tile_pieces += 1
                    accepted_way = True
            if accepted_way:
                source_ways += 1
                by_type[subtype] += 1
    sectors = []
    for (tx, tz), records in sorted(tiles.items()):
        records.sort(key=lambda record: (record["source_way"], record["id"], record["a"], record["b"]))
        sectors.append([tx, tz, records])
    return {
        "format": 1,
        "tile_size": tile_size,
        "source": "OSM highway=construction; render-only, non-drivable",
        "routing": False,
        "collision": False,
        "sectors": sectors,
        "stats": {
            "source_ways": source_ways,
            "source_segments": source_segments,
            "tile_pieces": tile_pieces,
            "tiles": len(sectors),
            "by_construction_type": dict(sorted(by_type.items())),
        },
    }
