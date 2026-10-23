#!/usr/bin/env python3
"""Compile explicit OSM roadside point truth for Yardman presentation.

Only source-tagged point features are accepted. This sidecar never creates road
routing, collision, inferred spacing, or guessed Jamaican infrastructure.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from collections import Counter, defaultdict
from pathlib import Path
from typing import Iterable

CRS_SOURCE = "EPSG:4326"
CRS_TARGET = "EPSG:3448"
ORIGIN_LAT = 17.9714
ORIGIN_LON = -76.7936
DEFAULT_TILE_SIZE = 4096.0
YES = {"yes", "true", "1"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path, help="OSM PBF or GeoJSON FeatureCollection")
    parser.add_argument("output", type=Path, help="Output roadside_points.json")
    parser.add_argument("--tile-size", type=float, default=DEFAULT_TILE_SIZE)
    parser.add_argument("--terrain", type=Path, help="Optional compiled terrain root")
    return parser.parse_args()


def _tags(feature: dict) -> dict:
    tags = dict(feature.get("properties") or {})
    nested = tags.get("tags")
    if isinstance(nested, dict):
        tags.update(nested)
    return tags


def classify_point(tags: dict) -> str | None:
    highway = str(tags.get("highway", "") or "").strip().lower()
    if highway == "street_lamp":
        return "street_lamp"
    if highway == "bus_stop" and str(tags.get("shelter", "") or "").strip().lower() in YES:
        return "bus_shelter"
    return None


def _pbf_features(path: Path) -> list[dict]:
    import osmium

    class Points(osmium.SimpleHandler):
        def __init__(self) -> None:
            super().__init__()
            self.features: list[dict] = []

        def node(self, node) -> None:
            tags = dict(node.tags)
            if classify_point(tags) is None:
                return
            if not node.location.valid():
                raise ValueError(f"Invalid location for OSM node {node.id}")
            self.features.append({
                "type": "Feature",
                "id": f"n{node.id}",
                "properties": tags,
                "geometry": {
                    "type": "Point",
                    "coordinates": [float(node.location.lon), float(node.location.lat)],
                },
            })

    handler = Points()
    handler.apply_file(str(path))
    return handler.features


def read_features(path: Path) -> list[dict]:
    if path.suffix.lower() == ".pbf":
        return _pbf_features(path)
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("type") != "FeatureCollection":
        raise ValueError("Expected OSM PBF or GeoJSON FeatureCollection")
    features = payload.get("features", [])
    if not isinstance(features, list):
        raise ValueError("GeoJSON features must be an array")
    return features


def _default_transformer():
    # Keep pyproj out of pure compiler-contract tests. Production national builds
    # already depend on pyproj and resolve the real EPSG:3448 transform here.
    from pyproj import Transformer
    return Transformer.from_crs(CRS_SOURCE, CRS_TARGET, always_xy=True)


def compile_points(features: Iterable[dict], tile_size: float = DEFAULT_TILE_SIZE,
                   height_sampler=None, transformer=None) -> dict:
    if not math.isfinite(tile_size) or tile_size <= 0.0:
        raise ValueError("tile_size must be finite and positive")
    if transformer is None:
        transformer = _default_transformer()
    origin_e, origin_n = transformer.transform(ORIGIN_LON, ORIGIN_LAT)
    sectors: dict[tuple[int, int], list[dict]] = defaultdict(list)
    counts: Counter[str] = Counter()
    ids: set[str] = set()

    for feature in features:
        if not isinstance(feature, dict):
            continue
        geometry = feature.get("geometry") or {}
        if geometry.get("type") != "Point":
            continue
        tags = _tags(feature)
        kind = classify_point(tags)
        if kind is None:
            continue
        coords = geometry.get("coordinates") or []
        if not isinstance(coords, (list, tuple)) or len(coords) < 2:
            continue
        lon, lat = float(coords[0]), float(coords[1])
        if not math.isfinite(lon) or not math.isfinite(lat):
            raise ValueError("Non-finite roadside point coordinate")
        easting, northing = transformer.transform(lon, lat)
        x = round(float(easting) - origin_e, 3)
        z = round(origin_n - float(northing), 3)
        y = round(float(height_sampler(x, z)), 6) if height_sampler else 0.0
        if not all(math.isfinite(value) for value in (x, y, z)):
            raise ValueError("Non-finite compiled roadside point")
        source_id = str(feature.get("id") or tags.get("@id") or "")
        if not source_id:
            source_id = "geojson-" + hashlib.sha1(
                repr((round(lon, 8), round(lat, 8), sorted(tags.items()))).encode()
            ).hexdigest()[:20]
        if source_id in ids:
            continue
        ids.add(source_id)
        tx, tz = math.floor(x / tile_size), math.floor(z / tile_size)
        record = {
            "id": source_id,
            "kind": kind,
            "position": [x, y, z],
            "elevation_source": "DEM" if height_sampler else "runtime-terrain-grounded",
            "source_tags": {
                key: str(tags[key]) for key in (
                    "highway", "shelter", "public_transport", "bus", "lit",
                    "lamp_mount", "support", "name"
                ) if key in tags
            },
        }
        sectors[(tx, tz)].append(record)
        counts[kind] += 1

    output_sectors = []
    for (tx, tz), records in sorted(sectors.items()):
        records.sort(key=lambda item: (item["kind"], item["id"]))
        output_sectors.append([tx, tz, records])
    return {
        "format": 1,
        "tile_size": float(tile_size),
        "crs": CRS_TARGET,
        "origin": {"lat": ORIGIN_LAT, "lon": ORIGIN_LON,
                   "easting": origin_e, "northing": origin_n},
        "source_contract": "explicit OSM point tags only",
        "geographic_authority": True,
        "routing": False,
        "navigation": False,
        "collision": False,
        "inferred_spacing": False,
        "kinds": {
            "street_lamp": "highway=street_lamp",
            "bus_shelter": "highway=bus_stop AND shelter=yes/true/1",
        },
        "sectors": output_sectors,
        "stats": {
            "points": sum(counts.values()),
            "tiles": len(output_sectors),
            "by_kind": dict(sorted(counts.items())),
        },
    }


def compile_file(input_path: Path, output_path: Path, tile_size: float = DEFAULT_TILE_SIZE,
                 height_sampler=None, transformer=None) -> dict:
    payload = compile_points(read_features(input_path), tile_size, height_sampler, transformer)
    payload["source"] = "OpenStreetMap / Geofabrik Jamaica extract"
    payload["source_sha256"] = hashlib.sha256(input_path.read_bytes()).hexdigest()
    payload["attribution"] = "© OpenStreetMap contributors — https://www.openstreetmap.org/copyright (ODbL)"
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    return payload


def main() -> int:
    args = parse_args()
    sampler = None
    if args.terrain:
        from build_terrain import TerrainSampler
        sampler = TerrainSampler(args.terrain)
    payload = compile_file(args.input, args.output, args.tile_size, sampler)
    print(json.dumps(payload["stats"], sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
