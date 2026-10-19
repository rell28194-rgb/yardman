#!/usr/bin/env python3
"""Remove runtime building footprints that physically occupy a same-grade road deck.

Both roads and buildings remain source-traceable. This pass resolves a rendering
conflict in favour of the drivable road surface and writes an audit containing
all removed OSM building-part IDs. Bridge/tunnel road surfaces are ignored here
because they may cross buildings/structures at a different elevation.
"""
from __future__ import annotations

import argparse
import gzip
import json
import math
import shutil
from collections import Counter
from pathlib import Path

import shapely
from shapely.geometry import Polygon
from shapely.strtree import STRtree

from build_buildings import CELL_SIZE, TILE_SIZE, read_cell, write_pack

ROAD_FLAG_BRIDGE = 2
ROAD_FLAG_TUNNEL = 4
DEFAULT_MIN_OVERLAP_M2 = 0.75


class RoadSurfaceIndex:
    def __init__(self, roads_root: Path):
        self.root = Path(roads_root)
        self.manifest = json.loads((self.root / "manifest.json").read_text(encoding="utf-8"))
        self.tile_size = float(self.manifest.get("tile_size", TILE_SIZE))
        if not math.isfinite(self.tile_size) or self.tile_size <= 0:
            raise ValueError("Road manifest has invalid tile size")
        self._files = {(int(t["x"]), int(t["z"])): str(t["file"]) for t in self.manifest.get("tiles", [])}
        self._cache: dict[tuple[int, int], tuple[list[Polygon], STRtree | None]] = {}

    def _load(self, tile: tuple[int, int]) -> tuple[list[Polygon], STRtree | None]:
        if tile in self._cache:
            return self._cache[tile]
        filename = self._files.get(tile)
        surfaces: list[Polygon] = []
        if filename:
            payload = json.loads((self.root / filename).read_text(encoding="utf-8"))
            for segment in payload.get("segments", []):
                if not isinstance(segment, list) or len(segment) < 12:
                    continue
                flags = int(segment[6])
                if flags & (ROAD_FLAG_BRIDGE | ROAD_FLAG_TUNNEL):
                    continue
                points = segment[11]
                if not isinstance(points, list) or len(points) < 3:
                    continue
                try:
                    polygon = Polygon([(float(p[0]), float(p[2])) for p in points])
                except (TypeError, ValueError, IndexError):
                    continue
                if polygon.is_empty or polygon.area <= 1e-6:
                    continue
                if not polygon.is_valid:
                    polygon = shapely.make_valid(polygon)
                parts = polygon.geoms if hasattr(polygon, "geoms") else [polygon]
                for part in parts:
                    if isinstance(part, Polygon) and not part.is_empty and part.area > 1e-6:
                        surfaces.append(part)
        tree = STRtree(surfaces) if surfaces else None
        self._cache[tile] = (surfaces, tree)
        return self._cache[tile]

    def conflict(self, building: Polygon, min_overlap_m2: float) -> tuple[bool, float]:
        x0, z0, x1, z1 = building.bounds
        best = 0.0
        for tx in range(math.floor(x0 / self.tile_size), math.floor(x1 / self.tile_size) + 1):
            for tz in range(math.floor(z0 / self.tile_size), math.floor(z1 / self.tile_size) + 1):
                surfaces, tree = self._load((tx, tz))
                if tree is None:
                    continue
                for raw_index in tree.query(building):
                    candidate = surfaces[int(raw_index)]
                    if not candidate.intersects(building):
                        continue
                    area = float(candidate.intersection(building).area)
                    if math.isfinite(area):
                        best = max(best, area)
                    if best >= min_overlap_m2:
                        return True, best
        return False, best


def record_polygon(record: list, global_cx: int, global_cz: int) -> Polygon | None:
    if not isinstance(record, list) or len(record) < 6 or not isinstance(record[5], list) or not record[5]:
        return None
    ox, oz = global_cx * CELL_SIZE, global_cz * CELL_SIZE
    rings = []
    for ring in record[5]:
        if not isinstance(ring, list) or len(ring) < 3:
            continue
        coords = []
        for point in ring:
            if not isinstance(point, list) or len(point) < 3:
                continue
            coords.append((ox + float(point[0]), oz + float(point[2])))
        if len(coords) >= 3:
            rings.append(coords)
    if not rings:
        return None
    polygon = Polygon(rings[0], rings[1:])
    if not polygon.is_valid:
        polygon = shapely.make_valid(polygon)
    if not isinstance(polygon, Polygon) or polygon.is_empty:
        return None
    return polygon


def filter_dataset(buildings_root: Path, roads_root: Path, output_root: Path | None = None,
                   audit_path: Path | None = None, min_overlap_m2: float = DEFAULT_MIN_OVERLAP_M2) -> dict:
    buildings_root = Path(buildings_root)
    roads_root = Path(roads_root)
    output_root = Path(output_root) if output_root else buildings_root
    if not math.isfinite(min_overlap_m2) or min_overlap_m2 <= 0:
        raise ValueError("min overlap must be finite and positive")
    manifest = json.loads((buildings_root / "manifest.json").read_text(encoding="utf-8"))
    road_index = RoadSurfaceIndex(roads_root)
    staging = output_root.with_name(output_root.name + ".road-clearance-staging")
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)

    stats = Counter()
    conflicts = []
    new_tiles = []
    for tile in manifest.get("tiles", []):
        tx, tz = int(tile["x"]), int(tile["z"])
        source_path = buildings_root / str(tile["file"])
        payloads = []
        kept_cells = []
        for local_x, local_z in tile.get("cells", []):
            local_x, local_z = int(local_x), int(local_z)
            records = read_cell(source_path, local_x, local_z)
            kept = []
            global_cx, global_cz = tx * (TILE_SIZE // CELL_SIZE) + local_x, tz * (TILE_SIZE // CELL_SIZE) + local_z
            for record in records:
                stats["checked_buildings"] += 1
                polygon = record_polygon(record, global_cx, global_cz)
                if polygon is None:
                    stats["invalid_runtime_footprint"] += 1
                    kept.append(record)
                    continue
                conflict, overlap = road_index.conflict(polygon, min_overlap_m2)
                if conflict:
                    stats["rejected_road_overlap"] += 1
                    conflicts.append({
                        "building_part_id": str(record[0]) if record else "",
                        "tile": [tx, tz],
                        "cell": [global_cx, global_cz],
                        "overlap_m2": round(overlap, 3),
                    })
                    continue
                kept.append(record)
            if kept:
                raw = json.dumps(kept, separators=(",", ":"), allow_nan=False).encode()
                payloads.append((local_x, local_z, gzip.compress(raw, compresslevel=6, mtime=0)))
                kept_cells.append([local_x, local_z])
                stats["kept_buildings"] += len(kept)
        if payloads:
            filename = str(tile["file"])
            write_pack(staging / filename, payloads)
            new_tile = dict(tile)
            new_tile["cells"] = kept_cells
            new_tiles.append(new_tile)

    updated = dict(manifest)
    updated["tiles"] = new_tiles
    updated_stats = dict(manifest.get("stats", {}))
    original_buildings = int(updated_stats.get("buildings", stats["checked_buildings"]))
    updated_stats["buildings_before_road_clearance"] = original_buildings
    updated_stats["rejected_road_overlap"] = int(stats["rejected_road_overlap"])
    updated_stats["buildings"] = int(stats["kept_buildings"])
    updated["stats"] = updated_stats
    updated["road_clearance"] = {
        "policy": "reject building footprint when same-grade rendered road ribbon overlap reaches threshold",
        "min_overlap_m2": min_overlap_m2,
        "bridge_tunnel_surfaces_excluded": True,
        "road_source_sha256": road_index.manifest.get("source_sha256", ""),
    }
    (staging / "manifest.json").write_text(json.dumps(updated, indent=2, sort_keys=True), encoding="utf-8")

    audit = {
        "format": 1,
        "buildings_checked": int(stats["checked_buildings"]),
        "buildings_kept": int(stats["kept_buildings"]),
        "rejected_road_overlap": int(stats["rejected_road_overlap"]),
        "invalid_runtime_footprint": int(stats["invalid_runtime_footprint"]),
        "min_overlap_m2": min_overlap_m2,
        "conflicts": conflicts,
    }
    final_audit = audit_path if audit_path else staging / "road_overlap_audit.json"
    if audit_path:
        Path(audit_path).parent.mkdir(parents=True, exist_ok=True)
        Path(audit_path).write_text(json.dumps(audit, indent=2, sort_keys=True), encoding="utf-8")
    else:
        final_audit.write_text(json.dumps(audit, indent=2, sort_keys=True), encoding="utf-8")

    if output_root.exists() and output_root != buildings_root:
        shutil.rmtree(output_root)
    if output_root == buildings_root:
        backup = buildings_root.with_name(buildings_root.name + ".pre-road-clearance")
        if backup.exists():
            shutil.rmtree(backup)
        buildings_root.replace(backup)
        staging.replace(buildings_root)
        shutil.rmtree(backup)
    else:
        staging.replace(output_root)
    return audit


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("buildings", type=Path)
    parser.add_argument("roads", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--audit", type=Path)
    parser.add_argument("--min-overlap-m2", type=float, default=DEFAULT_MIN_OVERLAP_M2)
    args = parser.parse_args()
    audit = filter_dataset(args.buildings, args.roads, args.output, args.audit, args.min_overlap_m2)
    print("YARDMAN_BUILDING_ROAD_CLEARANCE_PASS", json.dumps({k: v for k, v in audit.items() if k != "conflicts"}, sort_keys=True), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
