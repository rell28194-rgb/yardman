"""Compile OSM highway=construction lines as non-drivable Yardman work-zone truth.

This module is intentionally separate from road_graph.py. Construction ways are
presentation evidence for active/incomplete road works; they must never become
routing edges, collision ribbons, parish coverage, or ordinary drivable roads.
"""
from __future__ import annotations

import hashlib
import math
from collections import Counter, defaultdict

from road_graph import road_dimensions, split_segment

CONSTRUCTION_WIDTHS = {
    "motorway": 8.4, "motorway_link": 4.6,
    "trunk": 8.0, "trunk_link": 4.3,
    "primary": 7.2, "primary_link": 4.0,
    "secondary": 6.8, "secondary_link": 3.8,
    "tertiary": 6.4, "tertiary_link": 3.6,
    "unclassified": 5.8, "residential": 5.5,
    "living_street": 4.5, "service": 3.5,
    "road": 5.8, "track": 3.0, "raceway": 8.0,
}
DEFAULT_WIDTH_M = 5.8


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
    output segment preserves source identity, construction subtype, width/surface
    evidence and exact transformed endpoints. DEM elevation is sampled when
    available. The payload is explicitly non-drivable and non-navigable.
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
        surface = str(tags.get("surface", "unknown") or "unknown").lower()
        dimension_class = subtype if subtype in CONSTRUCTION_WIDTHS else "road"
        dimension_tags = dict(tags)
        dimension_tags["highway"] = dimension_class
        width, lanes, width_source = road_dimensions(
            dimension_tags, CONSTRUCTION_WIDTHS.get(dimension_class, DEFAULT_WIDTH_M))
        accepted_feature = False
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
            accepted_line = False
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
                        "construction_class": subtype,
                        "access": access,
                        "surface": surface,
                        "width_m": round(float(width), 3),
                        "lanes": int(lanes),
                        "width_source": str(width_source),
                        "a": [round(float(v), 3) for v in p],
                        "b": [round(float(v), 3) for v in q],
                        "length_m": round(length, 3),
                        "elevation_source": "DEM" if height_sampler else "unmeasured-flat",
                    }
                    tiles[(tx, tz)].append(record)
                    tile_pieces += 1
                    accepted_line = True
                    accepted_feature = True
            if accepted_line:
                by_type[subtype] += 1
        if accepted_feature:
            source_ways += 1
    sectors = []
    for (tx, tz), records in sorted(tiles.items()):
        records.sort(key=lambda record: (record["source_way"], record["id"], record["a"], record["b"]))
        sectors.append([tx, tz, records])
    return {
        "format": 1,
        "tile_size": tile_size,
        "source": "OSM highway=construction; render-only, non-drivable",
        "source_contract": "OpenStreetMap highway=construction only",
        "drivable": False,
        "navigation": False,
        "routing": False,
        "collision": False,
        "geographic_authority": True,
        "presentation_use": "temporary work-zone props only",
        "sectors": sectors,
        "stats": {
            "source_ways": source_ways,
            "source_segments": source_segments,
            "tile_pieces": tile_pieces,
            "tiles": len(sectors),
            "by_construction_type": dict(sorted(by_type.items())),
        },
    }
