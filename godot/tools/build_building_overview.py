#!/usr/bin/env python3
"""Compile streamed building HLOD proxies from final post-clearance YMB packs.

The overview is generated only after road/building conflict resolution. It uses
bounded linear ring math rather than geometry reconstruction, so one million
source masses do not become a second expensive national geometry pass.
"""
from __future__ import annotations

import argparse
import gzip
import json
import math
from pathlib import Path

from build_buildings import CELL_SIZE, HEADER, INDEX, MAGIC

TILE_SIZE = 4096.0
DENSITY_BIN_M = 32.0
MAX_PROXIES_PER_BIN = 2
MIN_PROXY_AREA_M2 = 5.0
MAX_TILE_INSTANCES = 32768


def read_pack(path: Path):
    with path.open("rb") as handle:
        magic, count = HEADER.unpack(handle.read(HEADER.size))
        if magic != MAGIC or count > 256:
            raise ValueError(f"Invalid building pack header: {path}")
        size = path.stat().st_size
        data_start = HEADER.size + count * INDEX.size
        entries = []
        for _ in range(count):
            x, z, offset, length = INDEX.unpack(handle.read(INDEX.size))
            if offset < data_start or offset + length > size:
                raise ValueError(f"Invalid building cell index: {path}")
            entries.append((x, z, offset, length))
        cells = []
        for x, z, offset, length in entries:
            handle.seek(offset)
            records = json.loads(gzip.decompress(handle.read(length)))
            if not isinstance(records, list):
                raise ValueError(f"Building cell is not a record list: {path}")
            cells.append((x, z, records))
        return cells


def base_offset_from_form(form: dict) -> float:
    try:
        value = float(form.get("min_height_m", 0.0))
        if math.isfinite(value) and value > 0.0:
            return value
    except (TypeError, ValueError):
        pass
    try:
        value = float(form.get("min_level", 0.0))
        if math.isfinite(value) and value > 0.0:
            return value * 3.15
    except (TypeError, ValueError):
        pass
    return 0.0


def _signed_ring_area(points) -> float:
    area = 0.0
    for index in range(len(points)):
        a = points[index]
        b = points[(index + 1) % len(points)]
        area += a[0] * b[1] - b[0] * a[1]
    return area * 0.5


def _proxy(record, local_cell_x: int, local_cell_z: int):
    if not isinstance(record, list) or len(record) not in {8, 9} or not isinstance(record[5], list) or not record[5]:
        return None
    origin_x = local_cell_x * CELL_SIZE
    origin_z = local_cell_z * CELL_SIZE
    rings = []
    foundations = []
    for source_ring in record[5]:
        if not isinstance(source_ring, list) or len(source_ring) < 3:
            continue
        ring = []
        for point in source_ring:
            if not isinstance(point, list) or len(point) != 3:
                continue
            x = origin_x + float(point[0])
            y = float(point[1])
            z = origin_z + float(point[2])
            if not all(math.isfinite(value) for value in (x, y, z)):
                return None
            ring.append((x, z))
            foundations.append(y)
        if len(ring) >= 3:
            rings.append(ring)
    if not rings or not foundations:
        return None

    area = abs(_signed_ring_area(rings[0]))
    for hole in rings[1:]:
        area -= abs(_signed_ring_area(hole))
    if not math.isfinite(area) or area < MIN_PROXY_AREA_M2:
        return None

    outer = rings[0]
    longest = 0.0
    axis_x, axis_z = 1.0, 0.0
    for index in range(len(outer)):
        a = outer[index]
        b = outer[(index + 1) % len(outer)]
        dx, dz = b[0] - a[0], b[1] - a[1]
        length = math.hypot(dx, dz)
        if length > longest:
            longest = length
            axis_x, axis_z = dx / length, dz / length
    if longest < 0.5:
        return None
    side_x, side_z = -axis_z, axis_x
    along = [point[0] * axis_x + point[1] * axis_z for point in outer]
    across = [point[0] * side_x + point[1] * side_z for point in outer]
    min_along, max_along = min(along), max(along)
    min_across, max_across = min(across), max(across)
    width = max_along - min_along
    depth = max_across - min_across
    yaw = math.atan2(axis_z, axis_x)
    if depth > width:
        width, depth = depth, width
        yaw += math.pi * 0.5
        axis_x, axis_z, side_x, side_z = side_x, side_z, -axis_x, -axis_z
        min_along, max_along, min_across, max_across = min_across, max_across, -max_along, -min_along
    if width < 0.5 or depth < 0.5:
        return None

    center_along = (min_along + max_along) * 0.5
    center_across = (min_across + max_across) * 0.5
    center_x = center_along * axis_x + center_across * side_x
    center_z = center_along * axis_z + center_across * side_z
    form = record[8] if len(record) == 9 and isinstance(record[8], dict) else {}
    base_y = min(foundations) + base_offset_from_form(form)
    top_y = float(record[4])
    height = top_y - base_y
    if not all(math.isfinite(value) for value in (center_x, center_z, width, depth, yaw, base_y, height)) or height < 0.5:
        return None
    if center_x < -512.0 or center_x > TILE_SIZE + 512.0 or center_z < -512.0 or center_z > TILE_SIZE + 512.0:
        return None

    kind = int(record[3]) if len(record) > 3 else 0
    packed = [round(center_x, 2), round(base_y, 2), round(center_z, 2),
              round(width, 2), round(height, 2), round(depth, 2), round(yaw, 5), kind]
    score = area + min(height, 80.0) * 8.0
    return packed, score


def compile_overview(buildings_root: Path) -> dict:
    manifest_path = buildings_root / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    tile_size = float(manifest.get("tile_size", 0.0))
    if not math.isclose(tile_size, TILE_SIZE, abs_tol=1e-6):
        raise ValueError("Building overview expects the canonical 4096 m tile grid")
    if not manifest.get("road_clearance"):
        raise ValueError("Building overview must be compiled from post-road-clearance packs")

    for stale in buildings_root.glob("far_buildings_*.json.gz"):
        stale.unlink()

    source_records = emitted = density_dropped = invalid_records = 0
    max_tile_instances = 0
    total_bytes = 0
    for tile in manifest.get("tiles", []):
        tx, tz = int(tile["x"]), int(tile["z"])
        bins = {}
        for local_x, local_z, records in read_pack(buildings_root / str(tile["file"])):
            for record in records:
                source_records += 1
                result = _proxy(record, local_x, local_z)
                if result is None:
                    invalid_records += 1
                    continue
                proxy, score = result
                bin_x = max(0, min(127, int(math.floor(proxy[0] / DENSITY_BIN_M))))
                bin_z = max(0, min(127, int(math.floor(proxy[2] / DENSITY_BIN_M))))
                key = (bin_x, bin_z)
                bucket = bins.setdefault(key, [])
                bucket.append((score, proxy))
                bucket.sort(key=lambda item: item[0], reverse=True)
                if len(bucket) > MAX_PROXIES_PER_BIN:
                    bucket.pop()
                    density_dropped += 1
        instances = [item[1] for key in sorted(bins) for item in bins[key]]
        if len(instances) > MAX_TILE_INSTANCES:
            raise ValueError(f"Building overview exceeds per-tile instance bound at {tx},{tz}: {len(instances)}")
        filename = f"far_buildings_{tx}_{tz}.json.gz"
        payload = json.dumps({"format": 1, "tile": [tx, tz], "instances": instances},
                             separators=(",", ":"), allow_nan=False).encode()
        compressed = gzip.compress(payload, compresslevel=6, mtime=0)
        (buildings_root / filename).write_bytes(compressed)
        tile["far_file"] = filename
        tile["far_instances"] = len(instances)
        emitted += len(instances)
        max_tile_instances = max(max_tile_instances, len(instances))
        total_bytes += len(compressed)

    manifest["far_overview"] = {
        "format": 1,
        "encoding": "deterministic gzip JSON",
        "source": "final post-road-clearance building packs",
        "tile_size": TILE_SIZE,
        "density_bin_m": DENSITY_BIN_M,
        "max_proxies_per_bin": MAX_PROXIES_PER_BIN,
        "near_handoff_m": 1200.0,
        "far_distance_m": 5600.0,
        "purpose": "render-only oriented building massing HLOD; no collision or navigation",
        "stats": {
            "source_records": source_records,
            "instances": emitted,
            "density_dropped": density_dropped,
            "invalid_or_tiny_records": invalid_records,
            "max_tile_instances": max_tile_instances,
            "compressed_bytes": total_bytes,
            "tiles": len(manifest.get("tiles", [])),
        },
    }
    temporary = manifest_path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(manifest, indent=2, sort_keys=True))
    temporary.replace(manifest_path)
    stats = manifest["far_overview"]["stats"]
    print("YARDMAN_BUILDING_OVERVIEW_PASS", json.dumps(stats, sort_keys=True), flush=True)
    return stats


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("buildings", type=Path)
    args = parser.parse_args()
    compile_overview(args.buildings)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())