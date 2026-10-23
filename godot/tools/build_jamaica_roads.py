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
from road_graph import build_network, partition_id, read_osm_features, split_segment
from work_zone_compile import compile_work_zones

CRS_SOURCE = "EPSG:4326"
CRS_TARGET = "EPSG:3448"
ORIGIN_LAT = 17.9714
ORIGIN_LON = -76.7936
DEFAULT_TILE_SIZE = 4096.0

ROAD_WIDTHS = {
    # These are individual carriageways, not an entire divided highway.
    # OSM width/lanes tags take precedence over these documented estimates.
    "motorway": 8.4, "motorway_link": 4.6,
    "trunk": 8.0, "trunk_link": 4.3,
    "primary": 7.2, "primary_link": 4.0,
    "secondary": 6.8, "secondary_link": 3.8,
    "tertiary": 6.4, "tertiary_link": 3.6,
    "unclassified": 5.8, "residential": 5.5,
    "living_street": 4.5, "service": 3.5,
    "road": 5.8, "track": 3.0, "raceway": 8.0,
}
ROAD_CLASSES = {name: i for i, name in enumerate(ROAD_WIDTHS)}
# The far LOD deliberately keeps Jamaica's arterial hierarchy rather than
# reproducing every lane/service road at kilometre-scale viewing distances.
ROAD_OVERVIEW_CLASSES = ("motorway", "trunk", "primary", "secondary", "tertiary")

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


def build_road_overview(network: dict, tile_size: float) -> dict:
    """Compile a cheap arterial road HLOD using the exact registered graph paths.

    The overview owns no collision or navigation. Every centreline piece is split
    at the same 4096 m world grid as the near renderer so it can stream by sector
    without forcing neighbouring full road tiles resident.
    """
    sectors = defaultdict(list)
    segment_count = 0
    for identifier, edge in sorted(network.get("edges", {}).items()):
        road_class = str(edge.get("class", ""))
        if road_class not in ROAD_OVERVIEW_CLASSES:
            continue
        path = edge.get("path", [])
        if not isinstance(path, list) or len(path) < 2:
            continue
        width = float(edge.get("width_m", ROAD_WIDTHS.get(road_class, 6.0)))
        class_id = int(edge.get("class_id", ROAD_CLASSES.get(road_class, 0)))
        flags = int(edge.get("flags", 0))
        # Tunnels do not draw through the mountain in the distant surface HLOD.
        # Bridge centreline elevations remain useful and are retained.
        if flags & 4:
            continue
        for a, b in zip(path, path[1:]):
            if len(a) < 3 or len(b) < 3 or math.dist(a[:3], b[:3]) < 0.25:
                continue
            for (tx, tz), p, q in split_segment(a, b, tile_size):
                sectors[(tx, tz)].append([
                    round(float(p[0]), 3), round(float(p[1]), 3), round(float(p[2]), 3),
                    round(float(q[0]), 3), round(float(q[1]), 3), round(float(q[2]), 3),
                    round(width, 3), class_id,
                ])
                segment_count += 1
    payload = {
        "format": 1,
        "tile_size": tile_size,
        "classes": list(ROAD_OVERVIEW_CLASSES),
        "segments": segment_count,
        "sectors": [[tx, tz, segments] for (tx, tz), segments in sorted(sectors.items())],
    }
    return payload


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
    overview = build_road_overview(network, tile_size)
    work_zones = compile_work_zones(features, transformer, (origin_e, origin_n), tile_size, height_sampler)
    if require_national_coverage and (overview["segments"] < 1000 or len(overview["sectors"]) < 20):
        raise ValueError("Far-road overview is too small for national arterial coverage")
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
    (staging / "overview.json").write_text(json.dumps(overview, separators=(",", ":")), encoding="utf-8")
    (staging / "work_zones.json").write_text(json.dumps(work_zones, separators=(",", ":")), encoding="utf-8")
    manifest = {
        "format": 3, "source": "OpenStreetMap / Geofabrik Jamaica extract",
        "source_sha256": hashlib.sha256(input_path.read_bytes()).hexdigest(),
        "attribution": "© OpenStreetMap contributors — https://www.openstreetmap.org/copyright (ODbL)",
        "crs": CRS_TARGET, "origin": {"lat": ORIGIN_LAT, "lon": ORIGIN_LON,
                                      "easting": origin_e, "northing": origin_n},
        "axis": "X=east, Y=elevation, Z=south, metres",
        "tile_size": tile_size, "bounds": [round(v, 3) for v in bounds],
        "road_classes": ROAD_CLASSES, "road_widths": ROAD_WIDTHS,
        "road_geometry": {"join": "shared bounded miter, complete source way before tile clipping",
                          "width": "source width, then source lanes, then carriageway-class estimate",
                          "uv": "continuous source-way station metres and signed lateral metres",
                          "markings": "inferred presentation, not surveyed road-paint positions"},
        "graph": {"format": 1, "partition": "sha1(id)[0:2]", "directory": "graph",
                  "nodes": stats["graph_nodes"], "edges": stats["graph_edges"]},
        "overview": {"format": 1, "file": "overview.json", "classes": list(ROAD_OVERVIEW_CLASSES),
                     "segments": overview["segments"], "sectors": len(overview["sectors"]),
                     "purpose": "render-only streamed arterial HLOD; no collision or navigation"},
        "work_zones": {"format": 1, "file": "work_zones.json",
                       "source_ways": work_zones["stats"]["source_ways"],
                       "segments": work_zones["stats"]["tile_pieces"],
                       "tiles": work_zones["stats"]["tiles"],
                       "purpose": "OSM highway=construction presentation evidence; no routing or collision"},
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
    # The road build is the canonical full-island data entry point used by the
    # reset Android workflow. Keep the authoritative admin_level=6 parish
    # polygons beside the streamed map data whenever the source is the Jamaica
    # PBF; GeoJSON road fixtures remain unaffected.
    if args.input_geojson.suffix.lower() == ".pbf":
        from build_parishes import compile_parishes
        parish_manifest = compile_parishes(args.input_geojson, args.output_dir.parent / "parishes")
        print("Packaged authoritative parish boundaries:", parish_manifest["stats"])
    print(json.dumps(manifest["stats"], indent=2, sort_keys=True))
    print("Far-road overview: %s segments / %s sectors" %
          (manifest["overview"]["segments"], manifest["overview"]["sectors"]))
    print("Construction work zones: %s source ways / %s streamed pieces / %s tiles" %
          (manifest["work_zones"]["source_ways"], manifest["work_zones"]["segments"], manifest["work_zones"]["tiles"]))
    print(f"Bounds (m): {manifest['bounds']}")
    print(f"Wrote {len(manifest['tiles'])} road tiles and persistent topology to {args.output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())