#!/usr/bin/env python3
"""Build Yardman's non-drivable construction sidecar from a Jamaica OSM PBF.

This is deliberately narrower than the full road compiler. It reads only OSM
highway ways, keeps highway=construction through work_zone_compile, and writes a
standalone artifact that can be staged beside an accepted world later. It does
not modify the accepted road graph, road surfaces, terrain, or navigation.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from pyproj import Transformer

from road_graph import read_osm_features
from work_zone_compile import compile_work_zones

CRS_SOURCE = "EPSG:4326"
CRS_TARGET = "EPSG:3448"
ORIGIN_LAT = 17.9714
ORIGIN_LON = -76.7936
DEFAULT_TILE_SIZE = 4096.0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("input_pbf", type=Path)
    parser.add_argument("output_json", type=Path)
    parser.add_argument("--tile-size", type=float, default=DEFAULT_TILE_SIZE)
    parser.add_argument("--source-url", default="")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.input_pbf.is_file() or args.input_pbf.stat().st_size <= 0:
        raise SystemExit("Jamaica OSM PBF is missing or empty")

    source_sha256 = hashlib.sha256(args.input_pbf.read_bytes()).hexdigest()
    transformer = Transformer.from_crs(CRS_SOURCE, CRS_TARGET, always_xy=True)
    origin_e, origin_n = transformer.transform(ORIGIN_LON, ORIGIN_LAT)
    features = read_osm_features(args.input_pbf)
    payload = compile_work_zones(
        features,
        transformer,
        (origin_e, origin_n),
        args.tile_size,
        height_sampler=None,
    )
    payload["source_snapshot"] = {
        "provider": "Geofabrik / OpenStreetMap contributors",
        "url": args.source_url,
        "pbf_sha256": source_sha256,
        "pbf_bytes": args.input_pbf.stat().st_size,
        "crs": CRS_TARGET,
        "origin": {
            "lat": ORIGIN_LAT,
            "lon": ORIGIN_LON,
            "easting": origin_e,
            "northing": origin_n,
        },
        "vertical_contract": "sidecar centreline Y is unmeasured; runtime grounds presentation to registered Yardman terrain",
    }

    if payload.get("drivable") is not False or payload.get("navigation") is not False:
        raise SystemExit("construction sidecar unexpectedly gained driving/navigation authority")
    if payload.get("routing") is not False or payload.get("collision") is not False:
        raise SystemExit("construction sidecar unexpectedly gained routing/collision authority")
    if payload.get("source_contract") != "OpenStreetMap highway=construction only":
        raise SystemExit("construction source contract drifted")

    args.output_json.parent.mkdir(parents=True, exist_ok=True)
    args.output_json.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    stats = payload.get("stats", {})
    print(
        "YARDMAN_NATIONAL_WORK_ZONE_SOURCE_BUILT "
        f"ways={int(stats.get('source_ways', 0))} "
        f"segments={int(stats.get('segments', 0))} "
        f"sectors={int(stats.get('sectors', 0))} "
        f"pbf_bytes={args.input_pbf.stat().st_size} sha256={source_sha256}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
