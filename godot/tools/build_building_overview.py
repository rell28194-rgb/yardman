#!/usr/bin/env python3
"""Compile streamed building HLOD proxies from final post-clearance YMB packs.

This runs after road/building conflict resolution, so distant massing cannot
resurrect a source footprint that the runtime removed for a severe carriageway
intrusion. The overview is presentation-only: no collision or navigation.
"""
from __future__ import annotations

import argparse
import gzip
import json
import math
from pathlib import Path

from resolve_building_road_conflicts import base_offset_from_form, read_pack, record_polygon

TILE_SIZE = 4096.0
DENSITY_BIN_M = 32.0
MAX_PROXIES_PER_BIN = 2
MIN_PROXY_AREA_M2 = 5.0
MAX_TILE_INSTANCES = 32768


def _proxy(record, polygon, tile_x: int, tile_z: int):
    if polygon.is_empty or polygon.area < MIN_PROXY_AREA_M2:
        return None
    rectangle = polygon.minimum_rotated_rectangle
    if rectangle.is_empty or not hasattr(rectangle, "exterior"):
        return None
    corners = list(rectangle.exterior.coords)[:4]
    if len(corners) != 4:
        return None
    edges = []
    for index in range(4):
        a, b = corners[index], corners[(index + 1) % 4]
        length = math.hypot(b[0] - a[0], b[1] - a[1])
        edges.append((length, a, b))
    first, second = edges[0], edges[1]
    if first[0] >= second[0]:
        width, depth = first[0], second[0]
        a, b = first[1], first[2]
    else:
        width, depth = second[0], first[0]
        a, b = second[1], second[2]
    if width < 0.5 or depth < 0.5:
        return None
    yaw = math.atan2(b[1] - a[1], b[0] - a[0])
    form = record[8] if len(record) == 9 and isinstance(record[8], dict) else {}
    base_offset = base_offset_from_form(form)
    foundations = [float(point[1]) for ring in record[5] for point in ring if len(point) == 3]
    if not foundations:
        return None
    base_y = min(foundations) + base_offset
    top_y = float(record[4])
    height = top_y - base_y
    if not all(math.isfinite(v) for v in (width, depth, yaw, base_y, top_y, height)) or height < 0.5:
        return None
    center = rectangle.centroid
    local_x = center.x - tile_x * TILE_SIZE
    local_z = center.y - tile_z * TILE_SIZE
    if local_x < -64.0 or local_x > TILE_SIZE + 64.0 or local_z < -64.0 or local_z > TILE_SIZE + 64.0:
        return None
    kind = int(record[3]) if len(record) > 3 else 0
    # [local x, base y, local z, width, height, depth, yaw, building kind]
    packed = [round(local_x, 2), round(base_y, 2), round(local_z, 2),
              round(width, 2), round(height, 2), round(depth, 2), round(yaw, 5), kind]
    score = float(polygon.area) + min(height, 80.0) * 8.0
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

    source_records = emitted = density_dropped = 0
    max_tile_instances = 0
    total_bytes = 0
    tile_metadata = []
    for tile in manifest.get("tiles", []):
        tx, tz = int(tile["x"]), int(tile["z"])
        bins = {}
        tile_source = 0
        for local_x, local_z, records in read_pack(buildings_root / str(tile["file"])):
            cell_x, cell_z = tx * 16 + local_x, tz * 16 + local_z
            for record in records:
                source_records += 1
                tile_source += 1
                polygon = record_polygon(record, cell_x, cell_z)
                result = _proxy(record, polygon, tx, tz)
                if result is None:
                    continue
                proxy, score = result
                bx = max(0, min(127, int(math.floor(proxy[0] / DENSITY_BIN_M))))
                bz = max(0, min(127, int(math.floor(proxy[2] / DENSITY_BIN_M))))
                key = (bx, bz)
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
        tile_metadata.append([tx, tz, len(instances), tile_source])

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
            "max_tile_instances": max_tile_instances,
            "compressed_bytes": total_bytes,
            "tiles": len(tile_metadata),
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