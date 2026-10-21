#!/usr/bin/env python3
"""Compile OSM Jamaica waterways into Yardman's accepted 4096 m projected grid."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
from typing import Dict, Iterable, List, Tuple

import osmium
from pyproj import Transformer

Point = Tuple[float, float]

DEFAULT_WIDTH = {
    "river": 12.0,
    "canal": 7.0,
    "stream": 3.0,
    "drain": 1.8,
    "ditch": 1.4,
}
KEEP = set(DEFAULT_WIDTH)


def canonical(value) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode()


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def parse_width(raw: str, default: float) -> float:
    if not raw:
        return default
    text = raw.strip().lower().replace("meters", "").replace("metres", "").replace("meter", "").replace("metre", "").replace("m", "").strip()
    try:
        value = float(text)
    except ValueError:
        return default
    return min(max(value, 0.7), 45.0)


def point_line_distance(p: Point, a: Point, b: Point) -> float:
    dx, dz = b[0] - a[0], b[1] - a[1]
    if abs(dx) + abs(dz) < 1e-12:
        return math.hypot(p[0] - a[0], p[1] - a[1])
    t = ((p[0] - a[0]) * dx + (p[1] - a[1]) * dz) / (dx * dx + dz * dz)
    t = min(max(t, 0.0), 1.0)
    qx, qz = a[0] + dx * t, a[1] + dz * t
    return math.hypot(p[0] - qx, p[1] - qz)


def simplify(points: List[Point], tolerance: float) -> List[Point]:
    if len(points) <= 2:
        return points
    a, b = points[0], points[-1]
    best_i, best_d = -1, -1.0
    for i in range(1, len(points) - 1):
        d = point_line_distance(points[i], a, b)
        if d > best_d:
            best_i, best_d = i, d
    if best_d <= tolerance:
        return [a, b]
    left = simplify(points[: best_i + 1], tolerance)
    right = simplify(points[best_i:], tolerance)
    return left[:-1] + right


def clipped_pieces(a: Point, b: Point, tile_size: float) -> Iterable[Tuple[Tuple[int, int], Point, Point]]:
    x1, z1 = a
    x2, z2 = b
    ts = [0.0, 1.0]
    dx, dz = x2 - x1, z2 - z1
    if abs(dx) > 1e-12:
        first = math.floor(min(x1, x2) / tile_size) + 1
        last = math.floor(max(x1, x2) / tile_size)
        for k in range(first, last + 1):
            t = (k * tile_size - x1) / dx
            if 1e-10 < t < 1.0 - 1e-10:
                ts.append(t)
    if abs(dz) > 1e-12:
        first = math.floor(min(z1, z2) / tile_size) + 1
        last = math.floor(max(z1, z2) / tile_size)
        for k in range(first, last + 1):
            t = (k * tile_size - z1) / dz
            if 1e-10 < t < 1.0 - 1e-10:
                ts.append(t)
    ts = sorted(set(round(t, 12) for t in ts))
    for ta, tb in zip(ts, ts[1:]):
        pa = (x1 + dx * ta, z1 + dz * ta)
        pb = (x1 + dx * tb, z1 + dz * tb)
        mid = ((pa[0] + pb[0]) * 0.5, (pa[1] + pb[1]) * 0.5)
        tile = (math.floor(mid[0] / tile_size), math.floor(mid[1] / tile_size))
        yield tile, pa, pb


class WaterwayHandler(osmium.SimpleHandler):
    def __init__(self, transformer: Transformer, origin_e: float, origin_n: float, tile_size: float, bounds: Dict[str, float]):
        super().__init__()
        self.transformer = transformer
        self.origin_e = origin_e
        self.origin_n = origin_n
        self.tile_size = tile_size
        self.bounds = bounds
        self.buckets: Dict[Tuple[int, int], Dict[Tuple[int, str], dict]] = {}
        self.source_ways = 0
        self.skipped_location = 0

    def way(self, way):
        kind = way.tags.get("waterway", "")
        if kind not in KEEP:
            return
        if way.tags.get("tunnel", "") not in ("", "no") or way.tags.get("covered", "") in ("yes", "true", "1"):
            return
        points: List[Point] = []
        try:
            for node in way.nodes:
                lon, lat = node.lon, node.lat
                e, n = self.transformer.transform(lon, lat)
                points.append((e - self.origin_e, self.origin_n - n))
        except (osmium.InvalidLocationError, RuntimeError):
            self.skipped_location += 1
            return
        if len(points) < 2:
            return
        tolerance = 1.5 if kind in ("river", "canal") else 2.5
        points = simplify(points, tolerance)
        default_width = DEFAULT_WIDTH[kind]
        width = parse_width(way.tags.get("width", ""), default_width)
        name = way.tags.get("name", "")
        intermittent = way.tags.get("intermittent", "") in ("yes", "true", "1") or way.tags.get("seasonal", "") not in ("", "no")
        self.source_ways += 1
        for a, b in zip(points, points[1:]):
            if (a[0] < self.bounds["min_x"] - self.tile_size and b[0] < self.bounds["min_x"] - self.tile_size) or (a[0] > self.bounds["max_x"] + self.tile_size and b[0] > self.bounds["max_x"] + self.tile_size):
                continue
            if (a[1] < self.bounds["min_z"] - self.tile_size and b[1] < self.bounds["min_z"] - self.tile_size) or (a[1] > self.bounds["max_z"] + self.tile_size and b[1] > self.bounds["max_z"] + self.tile_size):
                continue
            for tile, pa, pb in clipped_pieces(a, b, self.tile_size):
                tx, tz = tile
                local_a = (pa[0] - tx * self.tile_size, pa[1] - tz * self.tile_size)
                local_b = (pb[0] - tx * self.tile_size, pb[1] - tz * self.tile_size)
                key = (int(way.id), kind)
                bucket = self.buckets.setdefault(tile, {})
                record = bucket.get(key)
                if record is None:
                    record = {
                        "osm_way_id": int(way.id),
                        "kind": kind,
                        "name": name,
                        "width_m": round(width, 2),
                        "intermittent": intermittent,
                        "parts": [],
                    }
                    bucket[key] = record
                parts = record["parts"]
                if parts and math.hypot(parts[-1][-1][0] - local_a[0], parts[-1][-1][1] - local_a[1]) < 0.02:
                    parts[-1].append([round(local_b[0], 2), round(local_b[1], 2)])
                else:
                    parts.append([
                        [round(local_a[0], 2), round(local_a[1], 2)],
                        [round(local_b[0], 2), round(local_b[1], 2)],
                    ])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--pbf", required=True)
    ap.add_argument("--grid", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()

    pbf = Path(args.pbf)
    grid = json.loads(Path(args.grid).read_text())
    if grid.get("crs") != "EPSG:3448" or float(grid.get("tile_size", 0)) != 4096.0:
        raise SystemExit("unexpected Yardman accepted world grid")
    origin = grid["origin"]
    bounds = grid["world_bounds"]
    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)

    transformer = Transformer.from_crs("EPSG:4326", grid["crs"], always_xy=True)
    handler = WaterwayHandler(transformer, float(origin["easting"]), float(origin["northing"]), float(grid["tile_size"]), bounds)
    handler.apply_file(str(pbf), locations=True)

    tiles = []
    totals = {kind: 0 for kind in sorted(KEEP)}
    total_parts = total_points = 0
    for (tx, tz), records_by_way in sorted(handler.buckets.items()):
        if tx * grid["tile_size"] > bounds["max_x"] + grid["tile_size"] or (tx + 1) * grid["tile_size"] < bounds["min_x"] - grid["tile_size"]:
            continue
        if tz * grid["tile_size"] > bounds["max_z"] + grid["tile_size"] or (tz + 1) * grid["tile_size"] < bounds["min_z"] - grid["tile_size"]:
            continue
        records = sorted(records_by_way.values(), key=lambda r: (r["kind"], r["osm_way_id"]))
        for record in records:
            totals[record["kind"]] += 1
            total_parts += len(record["parts"])
            total_points += sum(len(part) for part in record["parts"])
        payload = {
            "format_version": 1,
            "tile": [tx, tz],
            "tile_size": grid["tile_size"],
            "waterways": records,
        }
        data = canonical(payload)
        filename = f"tile_{tx}_{tz}.json"
        (out / filename).write_bytes(data)
        tiles.append({"x": tx, "z": tz, "file": filename, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(), "waterways": len(records)})

    manifest = {
        "format_version": 1,
        "pack_id": "jamaica_hydrology_osm_v1",
        "crs": grid["crs"],
        "axis": grid["axis"],
        "origin": origin,
        "tile_size": grid["tile_size"],
        "source": "OpenStreetMap / Geofabrik Jamaica extract",
        "source_sha256": sha256_file(pbf),
        "attribution": "© OpenStreetMap contributors — https://www.openstreetmap.org/copyright (ODbL)",
        "license": "ODbL 1.0",
        "render_policy": {
            "active_tile_radius": 1,
            "max_active_tiles": 9,
            "max_vertices_per_tile": 12000,
            "collision": False,
            "planar_reflections": False,
            "shadows": False,
        },
        "stats": {
            "source_ways": handler.source_ways,
            "skipped_invalid_location": handler.skipped_location,
            "tiles": len(tiles),
            "parts": total_parts,
            "points": total_points,
            "waterways_by_class": totals,
        },
        "tiles": tiles,
    }
    (out / "manifest.json").write_bytes(canonical(manifest))
    print("YARDMAN_HYDROLOGY_COMPILED", json.dumps(manifest["stats"], sort_keys=True, separators=(",", ":")))
    if len(tiles) < 20 or total_parts < 100:
        raise SystemExit("hydrology extraction unexpectedly sparse")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
