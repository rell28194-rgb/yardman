#!/usr/bin/env python3
"""Build compact streamed Jamaica road tiles for Yardman from Osmium GeoJSON."""
from __future__ import annotations

import argparse
import json
import math
import shutil
from collections import Counter, defaultdict
from pathlib import Path
from typing import Dict, Iterator, List, Sequence, Tuple

from pyproj import Transformer

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
    p.add_argument("input_geojson", type=Path)
    p.add_argument("output_dir", type=Path)
    p.add_argument("--tile-size", type=float, default=DEFAULT_TILE_SIZE)
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


def main() -> int:
    args = parse_args()
    if args.tile_size <= 0:
        raise SystemExit("--tile-size must be positive")

    data = json.loads(args.input_geojson.read_text(encoding="utf-8"))
    if data.get("type") != "FeatureCollection":
        raise SystemExit("Expected a GeoJSON FeatureCollection from osmium export")

    out = args.output_dir
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True, exist_ok=True)

    transformer = Transformer.from_crs(CRS_SOURCE, CRS_TARGET, always_xy=True)
    origin_e, origin_n = transformer.transform(ORIGIN_LON, ORIGIN_LAT)
    anchor_local = {}
    for parish, (lat, lon) in PARISH_COVERAGE_ANCHORS.items():
        e, n = transformer.transform(lon, lat)
        anchor_local[parish] = (e - origin_e, origin_n - n)
    anchor_min_d2 = {parish: float("inf") for parish in anchor_local}

    tiles: Dict[Tuple[int, int], List[list]] = defaultdict(list)
    by_type: Counter[str] = Counter()
    feature_count = 0
    segment_count = 0
    skipped_non_drivable = 0
    degenerate_segments = 0
    min_x = min_z = float("inf")
    max_x = max_z = float("-inf")

    for feature in data.get("features", []):
        props = feature.get("properties") or {}
        highway = props.get("highway")
        if highway is None and isinstance(props.get("tags"), dict):
            highway = props["tags"].get("highway")
        if highway not in ROAD_WIDTHS:
            if highway:
                skipped_non_drivable += 1
            continue

        geometry = feature.get("geometry") or {}
        had_segment = False
        width = ROAD_WIDTHS[highway]
        class_id = ROAD_CLASSES[highway]
        flags = road_flags(props)

        for line in iter_lines(geometry):
            if len(line) < 2:
                continue
            projected: List[Tuple[float, float]] = []
            for lon, lat, *_ in line:
                e, n = transformer.transform(float(lon), float(lat))
                local = (e - origin_e, origin_n - n)
                projected.append(local)
                for parish, anchor in anchor_local.items():
                    d2 = (local[0] - anchor[0]) ** 2 + (local[1] - anchor[1]) ** 2
                    if d2 < anchor_min_d2[parish]:
                        anchor_min_d2[parish] = d2

            for (x1, z1), (x2, z2) in zip(projected, projected[1:]):
                if math.hypot(x2 - x1, z2 - z1) < 0.25:
                    degenerate_segments += 1
                    continue
                tile = midpoint_tile(x1, z1, x2, z2, args.tile_size)
                tiles[tile].append([
                    round(x1, 1), round(z1, 1), round(x2, 1), round(z2, 1),
                    width, class_id, flags,
                ])
                min_x = min(min_x, x1, x2)
                max_x = max(max_x, x1, x2)
                min_z = min(min_z, z1, z2)
                max_z = max(max_z, z1, z2)
                segment_count += 1
                had_segment = True

        if had_segment:
            feature_count += 1
            by_type[highway] += 1

    if segment_count == 0:
        raise SystemExit("No drivable road segments were generated")

    span_x = max_x - min_x
    span_z = max_z - min_z
    if span_x < 180000.0 or span_z < 45000.0:
        raise SystemExit(f"Road coverage is too small for Jamaica: span={span_x:.0f}m x {span_z:.0f}m")

    anchor_coverage = {parish: round(math.sqrt(d2), 1) for parish, d2 in anchor_min_d2.items()}
    missing_parishes = [name for name, distance in anchor_coverage.items() if distance > 10000.0]
    if missing_parishes:
        raise SystemExit(
            "Parish road coverage check failed (>10 km from nearest road): " + ", ".join(missing_parishes)
        )

    tile_entries = []
    for (tx, tz), segments in sorted(tiles.items()):
        name = f"tile_{tx}_{tz}.json"
        payload = {"tile": [tx, tz], "segments": segments}
        (out / name).write_text(json.dumps(payload, separators=(",", ":")), encoding="utf-8")
        tile_entries.append({"x": tx, "z": tz, "file": name, "segments": len(segments)})

    manifest = {
        "format": 1,
        "source": "OpenStreetMap / Geofabrik Jamaica extract",
        "crs": CRS_TARGET,
        "origin": {
            "lat": ORIGIN_LAT, "lon": ORIGIN_LON,
            "easting": round(origin_e, 3), "northing": round(origin_n, 3),
        },
        "axis": "X=east, Z=south, metres",
        "tile_size": args.tile_size,
        "bounds": [round(min_x, 1), round(min_z, 1), round(max_x, 1), round(max_z, 1)],
        "road_classes": ROAD_CLASSES,
        "road_widths": ROAD_WIDTHS,
        "tiles": tile_entries,
        "stats": {
            "road_features": feature_count,
            "segments": segment_count,
            "tiles": len(tile_entries),
            "skipped_non_drivable_features": skipped_non_drivable,
            "degenerate_segments": degenerate_segments,
            "by_highway_type": dict(sorted(by_type.items())),
            "parish_anchor_distance_m": anchor_coverage,
        },
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True), encoding="utf-8")

    print(json.dumps(manifest["stats"], indent=2, sort_keys=True))
    print(f"Bounds (m): {manifest['bounds']}")
    print(f"Wrote {len(tile_entries)} streamed road tiles to {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
