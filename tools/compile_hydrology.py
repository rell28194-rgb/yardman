#!/usr/bin/env python3
"""Compile source-backed Jamaica waterways into Yardman's 4096 m hydrology tiles.

Input is a Jamaica OSM PBF. Coordinates are transformed from WGS84 to
JAD2001 / Jamaica Metric Grid (EPSG:3448), then into Yardman's persistent
world coordinates using the exact accepted-world origin.

The output intentionally contains geometry/data only. Rendering, animation,
terrain height reconciliation and quality budgets remain runtime concerns.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

import osmium
from pyproj import Transformer
from shapely.geometry import GeometryCollection, LineString, MultiLineString, box

EPSG = "EPSG:3448"
ORIGIN_E = 771862.3076757698
ORIGIN_N = 646846.7138758468
TILE_SIZE = 4096.0
WORLD_BOUNDS = (-172032.0, -65536.0, 69632.0, 110592.0)
ALLOWED = {"river", "stream", "canal", "drain", "ditch"}
DEFAULT_WIDTH = {
    "river": 12.0,
    "stream": 2.4,
    "canal": 5.0,
    "drain": 1.5,
    "ditch": 1.0,
}
DEFAULT_FLOW = {
    "river": 1.05,
    "stream": 0.78,
    "canal": 0.42,
    "drain": 0.62,
    "ditch": 0.32,
}


def _truthy(value: str | None) -> bool:
    return (value or "").strip().lower() in {"yes", "true", "1"}


def _width_m(value: str | None, fallback: float) -> float:
    if not value:
        return fallback
    text = value.strip().lower().replace(",", ".")
    match = re.search(r"[-+]?\d+(?:\.\d+)?", text)
    if not match:
        return fallback
    number = float(match.group(0))
    if "ft" in text or "feet" in text or "foot" in text:
        number *= 0.3048
    elif "cm" in text:
        number *= 0.01
    return min(max(number, 0.35), 120.0)


def _iter_lines(geom) -> Iterable[LineString]:
    if geom.is_empty:
        return
    if isinstance(geom, LineString):
        if len(geom.coords) >= 2:
            yield geom
        return
    if isinstance(geom, MultiLineString):
        for part in geom.geoms:
            if len(part.coords) >= 2:
                yield part
        return
    if isinstance(geom, GeometryCollection):
        for part in geom.geoms:
            yield from _iter_lines(part)


@dataclass(frozen=True)
class Waterway:
    osm_id: int
    kind: str
    name: str
    width_m: float
    flow_mps: float
    points: tuple[tuple[float, float], ...]


class WaterwayHandler(osmium.SimpleHandler):
    def __init__(self) -> None:
        super().__init__()
        self.transformer = Transformer.from_crs("EPSG:4326", EPSG, always_xy=True)
        self.waterways: list[Waterway] = []
        self.skipped_intermit = 0
        self.skipped_underground = 0
        self.invalid_geometry = 0

    def way(self, way) -> None:
        kind = way.tags.get("waterway")
        if kind not in ALLOWED:
            return
        if _truthy(way.tags.get("intermittent")) or _truthy(way.tags.get("seasonal")):
            self.skipped_intermit += 1
            return
        if (
            _truthy(way.tags.get("tunnel"))
            or _truthy(way.tags.get("covered"))
            or (way.tags.get("location") or "").lower() == "underground"
        ):
            self.skipped_underground += 1
            return

        lonlat: list[tuple[float, float]] = []
        try:
            for node in way.nodes:
                if not node.location.valid():
                    self.invalid_geometry += 1
                    return
                lonlat.append((node.lon, node.lat))
        except osmium.InvalidLocationError:
            self.invalid_geometry += 1
            return
        if len(lonlat) < 2:
            return

        eastings, northings = self.transformer.transform(
            [p[0] for p in lonlat], [p[1] for p in lonlat]
        )
        points = tuple(
            (float(e) - ORIGIN_E, ORIGIN_N - float(n))
            for e, n in zip(eastings, northings)
        )
        self.waterways.append(
            Waterway(
                osm_id=int(way.id),
                kind=kind,
                name=(way.tags.get("name") or "").strip(),
                width_m=_width_m(way.tags.get("width"), DEFAULT_WIDTH[kind]),
                flow_mps=DEFAULT_FLOW[kind],
                points=points,
            )
        )


def _tile_range(min_v: float, max_v: float) -> range:
    start = math.floor(min_v / TILE_SIZE)
    end = math.floor(max_v / TILE_SIZE)
    return range(start, end + 1)


def compile_hydrology(pbf: Path, out_dir: Path) -> dict:
    handler = WaterwayHandler()
    handler.apply_file(str(pbf), locations=True)

    world_box = box(*WORLD_BOUNDS)
    tiles: dict[tuple[int, int], list[dict]] = defaultdict(list)
    by_kind: Counter[str] = Counter()
    source_way_count = 0
    clipped_piece_count = 0
    point_count = 0

    for waterway in handler.waterways:
        line = LineString(waterway.points)
        if line.is_empty or line.length < 0.5 or not line.intersects(world_box):
            continue
        line = line.intersection(world_box)
        if line.is_empty:
            continue
        source_way_count += 1
        for source_part in _iter_lines(line):
            # Preserve normal channel bends but discard sub-metre coordinate noise.
            source_part = source_part.simplify(0.75, preserve_topology=False)
            min_x, min_z, max_x, max_z = source_part.bounds
            for tx in _tile_range(min_x, max_x):
                for tz in _tile_range(min_z, max_z):
                    tile_box = box(
                        tx * TILE_SIZE,
                        tz * TILE_SIZE,
                        (tx + 1) * TILE_SIZE,
                        (tz + 1) * TILE_SIZE,
                    )
                    clipped = source_part.intersection(tile_box)
                    piece_index = 0
                    for piece in _iter_lines(clipped):
                        coords = [[round(float(x), 3), round(float(z), 3)] for x, z in piece.coords]
                        if len(coords) < 2:
                            continue
                        length_m = float(piece.length)
                        if length_m < 0.5:
                            continue
                        tiles[(tx, tz)].append(
                            {
                                "id": f"osm:{waterway.osm_id}:{piece_index}",
                                "source_way_id": waterway.osm_id,
                                "class": waterway.kind,
                                "name": waterway.name,
                                "width_m": round(waterway.width_m, 3),
                                "flow_mps": round(waterway.flow_mps, 3),
                                "length_m": round(length_m, 3),
                                "points": coords,
                            }
                        )
                        piece_index += 1
                        clipped_piece_count += 1
                        point_count += len(coords)
                        by_kind[waterway.kind] += 1

    out_dir.mkdir(parents=True, exist_ok=True)
    tile_records = []
    for (tx, tz), streams in sorted(tiles.items()):
        filename = f"water_{tx}_{tz}.json"
        payload = {
            "format_version": 1,
            "tile": [tx, tz],
            "streams": streams,
        }
        (out_dir / filename).write_text(
            json.dumps(payload, separators=(",", ":"), ensure_ascii=False), encoding="utf-8"
        )
        tile_records.append(
            {
                "x": tx,
                "z": tz,
                "file": filename,
                "streams": len(streams),
                "points": sum(len(s["points"]) for s in streams),
            }
        )

    manifest = {
        "format_version": 1,
        "crs": EPSG,
        "axis": "X=east, Y=elevation, Z=south, metres",
        "tile_size": TILE_SIZE,
        "origin": {"easting": ORIGIN_E, "northing": ORIGIN_N},
        "bounds": list(WORLD_BOUNDS),
        "source": "OpenStreetMap / Geofabrik Jamaica extract",
        "attribution": "© OpenStreetMap contributors — https://www.openstreetmap.org/copyright (ODbL)",
        "policy": {
            "included_waterway_classes": sorted(ALLOWED),
            "excluded_intermit_or_seasonal": True,
            "excluded_underground_or_covered": True,
            "runtime_height_source": "Yardman streamed terrain DEM",
        },
        "stats": {
            "source_waterways_seen": len(handler.waterways),
            "source_ways_compiled": source_way_count,
            "tile_pieces": clipped_piece_count,
            "points": point_count,
            "tiles": len(tile_records),
            "by_class": dict(sorted(by_kind.items())),
            "skipped_intermittent_or_seasonal": handler.skipped_intermit,
            "skipped_underground_or_covered": handler.skipped_underground,
            "invalid_geometry": handler.invalid_geometry,
        },
        "tiles": tile_records,
    }
    (out_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True), encoding="utf-8"
    )
    (out_dir / "ATTRIBUTION.txt").write_text(
        "Yardman hydrology geometry derived from OpenStreetMap data.\n"
        "© OpenStreetMap contributors. Data available under ODbL 1.0.\n"
        "https://www.openstreetmap.org/copyright\n",
        encoding="utf-8",
    )
    return manifest


def validate(manifest: dict) -> None:
    stats = manifest["stats"]
    if stats["tiles"] < 1:
        raise SystemExit("hydrology compiler produced no tiles")
    if stats["source_ways_compiled"] < 1:
        raise SystemExit("hydrology compiler produced no source waterways")
    if stats["points"] < stats["tile_pieces"] * 2:
        raise SystemExit("hydrology point accounting is invalid")
    bounds = manifest["bounds"]
    if bounds != list(WORLD_BOUNDS):
        raise SystemExit("hydrology world bounds drifted from accepted Yardman grid")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("pbf", type=Path)
    parser.add_argument("out_dir", type=Path)
    args = parser.parse_args()
    manifest = compile_hydrology(args.pbf, args.out_dir)
    validate(manifest)
    print(
        "YARDMAN_HYDROLOGY_COMPILE_PASS "
        f"tiles={manifest['stats']['tiles']} "
        f"ways={manifest['stats']['source_ways_compiled']} "
        f"pieces={manifest['stats']['tile_pieces']} "
        f"points={manifest['stats']['points']}"
    )


if __name__ == "__main__":
    main()
