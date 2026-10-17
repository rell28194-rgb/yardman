#!/usr/bin/env python3
"""Conservatively remove severe ground-building intrusions into road carriageways.

The road network remains authoritative. Registered OSM building geometry is only
adjusted when the compiled drivable ribbon materially penetrates a ground-origin
building edge and a single dominant building polygon survives. Ambiguous cases are
reported, not invented away.
"""
from __future__ import annotations

import argparse
import gzip
import json
import math
import shutil
import struct
from functools import lru_cache
from pathlib import Path

import shapely
from shapely.geometry import LineString, Polygon
from shapely.geometry.polygon import orient
from shapely.strtree import STRtree

from build_buildings import CELL_SIZE, HEADER, INDEX, MAGIC, conform_ring, write_pack
from build_terrain import TerrainSampler

CLEARANCE_MARGIN_M = 0.25
MIN_INTRUSION_DEPTH_M = 0.75
MIN_INTERSECTION_AREA_M2 = 0.75
MIN_RETAINED_AREA_RATIO = 0.68
MIN_REBUILT_AREA_M2 = 1.0
MAX_UNRESOLVED_EXAMPLES = 200
ELEVATED_EPSILON_M = 0.05
EXEMPT_BUILDING_TYPES = {"roof", "carport", "bridge"}


def read_pack(path: Path):
    """Return deterministic local-cell records from one YMB1 pack."""
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


def _closed_ring(points):
    result = list(points)
    if result and result[0] != result[-1]:
        result.append(result[0])
    return result


def record_polygon(record, cell_x: int, cell_z: int) -> Polygon:
    if not isinstance(record, list) or len(record) not in {8, 9}:
        raise ValueError("Unsupported building record")
    rings = record[5]
    if not rings or len(rings[0]) < 3:
        raise ValueError("Building record has no valid footprint ring")
    ox, oz = cell_x * CELL_SIZE, cell_z * CELL_SIZE
    converted = []
    for ring in rings:
        converted.append(_closed_ring((ox + float(p[0]), oz + float(p[2])) for p in ring))
    polygon = Polygon(converted[0], converted[1:])
    if not polygon.is_valid:
        polygon = shapely.make_valid(polygon)
    parts = polygon_parts(polygon)
    if not parts:
        raise ValueError("Building footprint could not be reconstructed")
    return max(parts, key=lambda item: item.area)


def polygon_parts(geometry):
    if geometry.is_empty:
        return []
    if isinstance(geometry, Polygon):
        return [geometry]
    return [part for part in getattr(geometry, "geoms", [])
            if isinstance(part, Polygon) and part.area >= MIN_REBUILT_AREA_M2]


def base_offset_from_form(form: dict) -> float:
    try:
        value = float(form.get("min_height_m", 0.0))
        if math.isfinite(value) and value > 0.0:
            return value
    except (TypeError, ValueError):
        pass
    try:
        level = float(form.get("min_level", 0.0))
        if math.isfinite(level) and level > 0.0:
            return level * 3.15
    except (TypeError, ValueError):
        pass
    return 0.0


def exempt_record(record) -> bool:
    form = record[8] if len(record) == 9 and isinstance(record[8], dict) else {}
    if base_offset_from_form(form) > ELEVATED_EPSILON_M:
        return True
    building_type = str(form.get("building_type", form.get("building_part_type", ""))).strip().lower()
    return building_type in EXEMPT_BUILDING_TYPES


def road_conflicts(polygon: Polygon, candidates: list[dict], tree: STRtree | None):
    """Return severe ribbon intrusions; shallow roadside contact remains untouched."""
    if tree is None or polygon.is_empty:
        return []
    conflicts = []
    seen = set()
    for raw_index in tree.query(polygon, predicate="intersects"):
        index = int(raw_index)
        road = candidates[index]
        key = road["key"]
        if key in seen:
            continue
        intersection = polygon.intersection(road["surface"])
        if intersection.is_empty or intersection.area < MIN_INTERSECTION_AREA_M2:
            continue
        distance = road["centerline"].distance(polygon)
        penetration = road["width_m"] * 0.5 - distance
        if penetration < MIN_INTRUSION_DEPTH_M:
            continue
        seen.add(key)
        conflicts.append(road)
    return conflicts


def resolve_polygon_conflict(polygon: Polygon, conflicts: list[dict]):
    """Clip a protruding edge only when one dominant registered mass survives."""
    if not conflicts:
        return polygon, False, False, 0.0
    exclusion = shapely.union_all([
        road["surface"].buffer(CLEARANCE_MARGIN_M, join_style=2)
        for road in conflicts
    ])
    clipped = polygon.difference(exclusion)
    if not clipped.is_valid:
        clipped = shapely.make_valid(clipped)
    parts = polygon_parts(clipped)
    if not parts:
        return polygon, False, True, 0.0
    largest = max(parts, key=lambda part: part.area)
    retained = largest.area / polygon.area if polygon.area > 0.0 else 0.0
    removed = max(0.0, polygon.area - largest.area)
    if retained < MIN_RETAINED_AREA_RATIO or largest.area < MIN_REBUILT_AREA_M2:
        return polygon, False, True, 0.0
    if removed < MIN_INTERSECTION_AREA_M2:
        return polygon, False, False, 0.0
    return largest, True, False, removed


def rebuild_record(record, polygon: Polygon, sampler, cell_x: int, cell_z: int, removed_area: float):
    polygon = orient(polygon, sign=1.0)
    ox, oz = cell_x * CELL_SIZE, cell_z * CELL_SIZE
    spacing = float(getattr(sampler, "spacing", 64.0))
    rings = [conform_ring(polygon.exterior.coords, sampler, spacing)]
    rings.extend(conform_ring(interior.coords, sampler, spacing) for interior in polygon.interiors)
    height = float(record[1])
    roof_y = round(max(point[1] for ring in rings for point in ring) + height, 5)

    vertices, indices, vertex_map = [], [], {}
    triangles = shapely.constrained_delaunay_triangles(polygon)
    for triangle in triangles.geoms:
        if triangle.area <= 1e-8 or not polygon.covers(triangle):
            raise ValueError("Road-adjusted roof triangle crosses footprint boundary")
        tri_indices = []
        for x, z in list(triangle.exterior.coords)[:3]:
            key = (round(x - ox, 4), round(z - oz, 4))
            if key not in vertex_map:
                vertex_map[key] = len(vertices)
                vertices.append(list(key))
            tri_indices.append(vertex_map[key])
        a, b, c = [vertices[index] for index in tri_indices]
        cross = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
        if cross > 0:
            tri_indices[1], tri_indices[2] = tri_indices[2], tri_indices[1]
        indices.extend(tri_indices)
    if not indices:
        raise ValueError("Road-adjusted footprint has no roof triangles")

    local_rings = [[[round(x - ox, 4), y, round(z - oz, 4)] for x, y, z in ring] for ring in rings]
    form = dict(record[8]) if len(record) == 9 and isinstance(record[8], dict) else {}
    form["road_clearance_adjusted"] = True
    form["road_clearance_removed_m2"] = round(removed_area, 3)
    form["road_clearance_policy"] = "compiled_carriageway_edge_conflict"
    return [record[0], record[1], record[2], record[3], roof_y,
            local_rings, vertices, indices, form]


def load_road_tile(path: Path):
    if not path.exists():
        return []
    payload = json.loads(path.read_text(encoding="utf-8"))
    roads = []
    for segment in payload.get("segments", []):
        if not isinstance(segment, list) or len(segment) < 12:
            continue
        flags = int(segment[6])
        # A building can legitimately sit under/over a grade-separated road.
        if flags & 2 or flags & 4:
            continue
        try:
            width = float(segment[4])
            a = (float(segment[0]), float(segment[1]))
            b = (float(segment[2]), float(segment[3]))
        except (TypeError, ValueError):
            continue
        if not math.isfinite(width) or width <= 0.0 or a == b:
            continue
        surface_points = segment[11]
        try:
            surface = Polygon([(float(point[0]), float(point[2])) for point in surface_points])
        except (TypeError, ValueError, IndexError):
            continue
        if surface.is_empty or surface.area <= 1e-6:
            continue
        if not surface.is_valid:
            surface = shapely.make_valid(surface)
            parts = polygon_parts(surface)
            if not parts:
                continue
            surface = max(parts, key=lambda item: item.area)
        roads.append({
            "surface": surface,
            "centerline": LineString([a, b]),
            "width_m": width,
            "key": (str(segment[7]) if len(segment) > 7 else "", int(segment[8]) if len(segment) > 8 else 0),
        })
    return roads


def compile_clearance(roads_root: Path, terrain_root: Path, buildings_root: Path):
    road_manifest = json.loads((roads_root / "manifest.json").read_text(encoding="utf-8"))
    building_manifest_path = buildings_root / "manifest.json"
    building_manifest = json.loads(building_manifest_path.read_text(encoding="utf-8"))
    road_tile_size = float(road_manifest.get("tile_size", 0.0))
    building_tile_size = float(building_manifest.get("tile_size", 0.0))
    if not math.isclose(road_tile_size, building_tile_size, abs_tol=1e-6):
        raise ValueError("Road/building tile-size mismatch")
    if not math.isclose(building_tile_size, 4096.0, abs_tol=1e-6):
        raise ValueError("Road-clearance pass expects 4096m national tiles")

    sampler = TerrainSampler(terrain_root)
    road_files = {(int(tile["x"]), int(tile["z"])): str(tile["file"])
                  for tile in road_manifest.get("tiles", [])}

    @lru_cache(maxsize=96)
    def cached_roads(tx: int, tz: int):
        filename = road_files.get((tx, tz))
        return load_road_tile(roads_root / filename) if filename else []

    max_reach = float(building_manifest.get("max_footprint_reach_m", 0.0) or 0.0)
    neighbor_radius = max(1, int(math.ceil(max_reach / building_tile_size)))
    stats = {
        "records_seen": 0,
        "elevated_or_grade_separated_buildings_skipped": 0,
        "records_with_severe_carriageway_intrusion": 0,
        "adjusted_buildings": 0,
        "unresolved_conflicts": 0,
        "removed_building_area_m2": 0.0,
        "tiles_rewritten": 0,
    }
    unresolved_examples = []
    staging = buildings_root.with_name(buildings_root.name + ".roadclearance")
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)

    known_pack_names = {str(tile["file"]) for tile in building_manifest.get("tiles", [])}
    for child in buildings_root.iterdir():
        if child.name == "manifest.json" or child.name in known_pack_names:
            continue
        target = staging / child.name
        if child.is_dir():
            shutil.copytree(child, target)
        else:
            shutil.copy2(child, target)

    for tile in building_manifest.get("tiles", []):
        tx, tz, filename = int(tile["x"]), int(tile["z"]), str(tile["file"])
        candidates = []
        for rz in range(tz - neighbor_radius, tz + neighbor_radius + 1):
            for rx in range(tx - neighbor_radius, tx + neighbor_radius + 1):
                candidates.extend(cached_roads(rx, rz))
        tree = STRtree([road["surface"] for road in candidates]) if candidates else None
        output_cells = []
        changed_tile = False
        for local_x, local_z, records in read_pack(buildings_root / filename):
            cell_x, cell_z = tx * 16 + local_x, tz * 16 + local_z
            rewritten = []
            for record in records:
                stats["records_seen"] += 1
                if exempt_record(record):
                    stats["elevated_or_grade_separated_buildings_skipped"] += 1
                    rewritten.append(record)
                    continue
                polygon = record_polygon(record, cell_x, cell_z)
                conflicts = road_conflicts(polygon, candidates, tree)
                if not conflicts:
                    rewritten.append(record)
                    continue
                stats["records_with_severe_carriageway_intrusion"] += 1
                adjusted, changed, unresolved, removed = resolve_polygon_conflict(polygon, conflicts)
                if unresolved:
                    stats["unresolved_conflicts"] += 1
                    if len(unresolved_examples) < MAX_UNRESOLVED_EXAMPLES:
                        unresolved_examples.append({
                            "building_id": str(record[0]),
                            "tile": [tx, tz],
                            "cell": [cell_x, cell_z],
                            "area_m2": round(polygon.area, 3),
                            "road_keys": [list(road["key"]) for road in conflicts[:8]],
                        })
                    rewritten.append(record)
                    continue
                if changed:
                    record = rebuild_record(record, adjusted, sampler, cell_x, cell_z, removed)
                    stats["adjusted_buildings"] += 1
                    stats["removed_building_area_m2"] += removed
                    changed_tile = True
                rewritten.append(record)
            raw = json.dumps(rewritten, separators=(",", ":"), allow_nan=False).encode()
            output_cells.append((local_x, local_z, gzip.compress(raw, compresslevel=6, mtime=0)))
        write_pack(staging / filename, output_cells)
        if changed_tile:
            stats["tiles_rewritten"] += 1

    stats["removed_building_area_m2"] = round(stats["removed_building_area_m2"], 3)
    building_manifest["record_format"] = max(2, int(building_manifest.get("record_format", 1)))
    building_manifest["road_clearance"] = {
        "policy": "Only severe ground-origin intersections with compiled non-bridge/non-tunnel carriageway ribbons are eligible. Shallow roadside contact is preserved. Adjustments require one dominant footprint retaining at least 68% of registered area; ambiguous cases remain unchanged and are reported.",
        "clearance_margin_m": CLEARANCE_MARGIN_M,
        "minimum_intrusion_depth_m": MIN_INTRUSION_DEPTH_M,
        "minimum_intersection_area_m2": MIN_INTERSECTION_AREA_M2,
        "minimum_retained_area_ratio": MIN_RETAINED_AREA_RATIO,
        "unresolved_examples_file": "road_clearance_report.json",
    }
    building_manifest.setdefault("stats", {}).update({
        "road_clearance_adjusted_buildings": stats["adjusted_buildings"],
        "road_clearance_unresolved_conflicts": stats["unresolved_conflicts"],
        "road_clearance_removed_area_m2": stats["removed_building_area_m2"],
    })
    (staging / "manifest.json").write_text(json.dumps(building_manifest, indent=2, sort_keys=True), encoding="utf-8")
    (staging / "road_clearance_report.json").write_text(json.dumps({
        "stats": stats,
        "unresolved_examples": unresolved_examples,
    }, indent=2, sort_keys=True), encoding="utf-8")

    backup = buildings_root.with_name(buildings_root.name + ".pre-roadclearance")
    if backup.exists():
        shutil.rmtree(backup)
    buildings_root.replace(backup)
    staging.replace(buildings_root)
    shutil.rmtree(backup)
    return stats


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("roads", type=Path)
    parser.add_argument("terrain", type=Path)
    parser.add_argument("buildings", type=Path)
    args = parser.parse_args()
    stats = compile_clearance(args.roads, args.terrain, args.buildings)
    print("YARDMAN_BUILDING_ROAD_CLEARANCE_PASS", json.dumps(stats, sort_keys=True), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
