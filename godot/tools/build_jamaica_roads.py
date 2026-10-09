#!/usr/bin/env python3
"""Build compact streamed Jamaica road tiles for Yardman from Osmium GeoJSON."""
from __future__ import annotations

import argparse
import json
import math
import shutil
import hashlib
from collections import Counter, defaultdict
from pathlib import Path
from typing import Dict, Iterator, List, Sequence, Tuple

from pyproj import Transformer
from road_graph import build_network, partition_id, read_osm_features

CRS_SOURCE = "EPSG:4326"
CRS_TARGET = "EPSG:3448"
ORIGIN_LAT = 17.9714
ORIGIN_LON = -76.7936
DEFAULT_TILE_SIZE = 4096.0

ROAD_WIDTHS = {
    "motorway": 14.0, "motorway_link": 8.0,
    "trunk": 12.0, "trunk_link": 7.5,
    "primary": 10.0, "primary_link": 7.0,
    "secondary": 9.0, "secondary_link": 6.5,
    "tertiary": 8.0, "tertiary_link": 6.0,
    "unclassified": 6.5, "residential": 6.0,
    "living_street": 5.0, "service": 5.0,
    "road": 6.0, "track": 4.0, "raceway": 9.0,
}
ROAD_CLASSES = {name: i for i, name in enumerate(ROAD_WIDTHS)}

# CI coverage sentinels. These parish-capital/administrative-centre anchors are
# only QA points: a partial-island road extract is not allowed to pass.
PARISH_COVERAGE_ANCHORS = {
    "Kingston": (17.9714, -76.7936),
    "St. Andrew": (18.0120, -76.7970),
    "St. Catherine": (17.9911, -76.9574),
    "Clarendon": (17.9645, -77.2451),
    "Manchester": (18.0417, -77.5071),
    "St. Elizabeth": (18.0264, -77.8487),
    "Westmoreland": (18.2190, -78.1332),
    "Hanover": (18.4510, -78.1736),
    "St. James": (18.4762, -77.8939),
    "Trelawny": (18.4936, -77.6559),
    "St. Ann": (18.4358, -77.2000),
    "St. Mary": (18.3685, -76.8895),
    "Portland": (18.1762, -76.4509),
    "St. Thomas": (17.8815, -76.4093),
}


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("input_geojson", type=Path, help="OSM PBF or GeoJSON")
    p.add_argument("output_dir", type=Path)
    p.add_argument("--tile-size", type=float, default=DEFAULT_TILE_SIZE)
    p.add_argument("--terrain", type=Path, help="Compiled terrain root for registered road elevation")
    return p.parse_args()


def iter_lines(geometry: dict) -> Iterator[Sequence[Sequence[float]]]:
    kind = geometry.get("type")
    coords = geometry.get("coordinates") or []
    if kind == "LineString":
        yield coords
    elif kind == "MultiLineString":
        yield from coords


def midpoint_tile(x1: float, z1: float, x2: float, z2: float, tile_size: float) -> Tuple[int, int]:
    return math.floor(((x1 + x2) * 0.5) / tile_size), math.floor(((z1 + z2) * 0.5) / tile_size)


def road_flags(properties: dict) -> int:
    flags = 0
    if str(properties.get("oneway", "")).lower() in {"yes", "1", "true", "-1"}:
        flags |= 1
    if str(properties.get("bridge", "")).lower() not in {"", "no", "0", "false"}:
        flags |= 2
    if str(properties.get("tunnel", "")).lower() not in {"", "no", "0", "false"}:
        flags |= 4
    if str(properties.get("surface", "")).lower() in {
        "unpaved", "gravel", "dirt", "ground", "earth", "sand", "mud", "compacted"
    }:
        flags |= 8
    return flags


def compile_dataset(input_path: Path, out: Path, tile_size: float = DEFAULT_TILE_SIZE,
                    require_national_coverage: bool = True, height_sampler=None) -> dict:
    if tile_size <= 0 or not math.isfinite(tile_size):
        raise ValueError("--tile-size must be finite and positive")
    if input_path.suffix == ".pbf":
        features = read_osm_features(input_path)
    else:
        data = json.loads(input_path.read_text(encoding="utf-8"))
        if data.get("type") != "FeatureCollection":
            raise ValueError("Expected a GeoJSON FeatureCollection or OSM PBF")
        features = data.get("features", [])
    transformer = Transformer.from_crs(CRS_SOURCE, CRS_TARGET, always_xy=True)
    origin_e, origin_n = transformer.transform(ORIGIN_LON, ORIGIN_LAT)
    anchors = {}
    for name, (lat, lon) in PARISH_COVERAGE_ANCHORS.items():
        e, n = transformer.transform(lon, lat)
        anchors[name] = (e - origin_e, origin_n - n)
    network = build_network(features, transformer, (origin_e, origin_n), tile_size,
                            ROAD_WIDTHS, ROAD_CLASSES, road_flags, anchors, height_sampler)
    stats, bounds = network["stats"], network["bounds"]
    if not stats["source_segments"]:
        raise ValueError("No drivable road segments were generated")
    if require_national_coverage:
        if bounds[2] - bounds[0] < 180000 or bounds[3] - bounds[1] < 45000:
            raise ValueError("Road coverage is too small for Jamaica")
        missing = [p for p, d in stats["parish_anchor_distance_m"].items() if d > 10000]
        if missing:
            raise ValueError("Missing parish coverage: " + ", ".join(missing))
    # Build into a sibling staging directory; failed compiles retain old outputs.
    staging = out.with_name(out.name + ".staging")
    if staging.exists():
        shutil.rmtree(staging)
    (staging / "graph").mkdir(parents=True)
    tile_entries = []
    for (tx, tz), segments in sorted(network["tiles"].items()):
        filename = f"tile_{tx}_{tz}.json"
        payload = {"tile": [tx, tz], "segments": segments}
        (staging / filename).write_text(json.dumps(payload, separators=(",", ":")))
        tile_entries.append({"x": tx, "z": tz, "file": filename, "segments": len(segments)})
    for kind in ("nodes", "edges"):
        partitions = defaultdict(dict)
        for identifier, item in sorted(network[kind].items()):
            partitions[partition_id(identifier)][identifier] = item
        for partition, values in sorted(partitions.items()):
            (staging / "graph" / f"{kind}_{partition}.json").write_text(
                json.dumps(values, separators=(",", ":")), encoding="utf-8")
    manifest = {
        "format": 2, "source": "OpenStreetMap / Geofabrik Jamaica extract",
        "source_sha256": hashlib.sha256(input_path.read_bytes()).hexdigest(),
        "attribution": "© OpenStreetMap contributors — https://www.openstreetmap.org/copyright (ODbL)",
        "crs": CRS_TARGET, "origin": {"lat": ORIGIN_LAT, "lon": ORIGIN_LON,
                                      "easting": origin_e, "northing": origin_n},
        "axis": "X=east, Y=elevation, Z=south, metres",
        "tile_size": tile_size, "bounds": [round(v, 3) for v in bounds],
        "road_classes": ROAD_CLASSES, "road_widths": ROAD_WIDTHS,
        "graph": {"format": 1, "partition": "sha1(id)[0:2]", "directory": "graph",
                  "nodes": stats["graph_nodes"], "edges": stats["graph_edges"]},
        "elevation_source": "DEM" if height_sampler else "unmeasured-flat",
        "tiles": tile_entries, "stats": stats,
        "parish_anchors": {name: {**network["anchor_roads"].get(name, {}), "lat": PARISH_COVERAGE_ANCHORS[name][0],
                                   "lon": PARISH_COVERAGE_ANCHORS[name][1],
                                   "x": position[0], "z": position[1]} for name, position in anchors.items()},
    }
    (staging / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True))
    if out.exists():
        shutil.rmtree(out)
    staging.replace(out)
    return manifest


def main() -> int:
    args = parse_args()
    sampler = None
    if args.terrain:
        from build_terrain import TerrainSampler
        sampler = TerrainSampler(args.terrain)
    manifest = compile_dataset(args.input_geojson, args.output_dir, args.tile_size, height_sampler=sampler)
    print(json.dumps(manifest["stats"], indent=2, sort_keys=True))
    print(f"Bounds (m): {manifest['bounds']}")
    print(f"Wrote {len(manifest['tiles'])} road tiles and persistent topology to {args.output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
