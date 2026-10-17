#!/usr/bin/env python3
"""Compile OSM building footprints into indexed, independently compressed cells.

Registered source footprints, terrain-conformed foundations, recorded height/levels,
source building parts, and source building-form tags are preserved independently
from presentation inference.
"""
from __future__ import annotations
import argparse
import gzip
import hashlib
import json
import math
import re
import shutil
import sqlite3
import struct
from collections import Counter, defaultdict
from pathlib import Path

import osmium
import shapely
from pyproj import Transformer
from shapely.geometry import Polygon
from shapely.ops import transform

TILE_SIZE = 4096
CELL_SIZE = 256
PART_BIN_SIZE = 512.0
MAGIC = b"YMB1"
INDEX = struct.Struct("<HHII")
HEADER = struct.Struct("<4sI")
HEIGHT_MEASURED, HEIGHT_LEVELS, HEIGHT_INFERRED = 1, 2, 3
HEIGHT_DEFAULTS = {"house": 4.1, "detached": 4.1, "residential": 4.1,
                   "garage": 3.0, "garages": 3.0, "shed": 2.6,
                   "hut": 2.8, "barn": 4.2, "warehouse": 6.5,
                   "industrial": 6.5, "apartments": 9.4,
                   "church": 9.0, "school": 4.5, "commercial": 5.5}
KINDS = {"house": 0, "detached": 0, "residential": 0, "apartments": 1,
         "industrial": 2, "warehouse": 2, "commercial": 3,
         "retail": 3, "school": 4, "church": 4,
         "garage": 5, "garages": 5, "shed": 5, "hut": 5}
FALSE_VALUES = {"no", "0", "false", ""}


def _source_type(tags: dict) -> str:
    building = str(tags.get("building", "")).strip().lower()
    if building not in FALSE_VALUES:
        return building
    part = str(tags.get("building:part", "")).strip().lower()
    return part if part not in FALSE_VALUES else "yes"


def _is_building(tags: dict) -> bool:
    return str(tags.get("building", "")).strip().lower() not in FALSE_VALUES


def _is_part(tags: dict) -> bool:
    return str(tags.get("building:part", "")).strip().lower() not in FALSE_VALUES


def parse_length(value: str, minimum=0.05, maximum=350.0) -> float | None:
    match = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*(m|metres?|meters?|ft|feet|')?\s*", str(value), re.I)
    if not match:
        return None
    result = float(match[1]) * (0.3048 if (match[2] or "").lower() in {"ft", "feet", "'"} else 1.0)
    return result if math.isfinite(result) and minimum <= result <= maximum else None


def parse_height(value: str) -> float | None:
    return parse_length(value, 1.0, 350.0)


def parse_levels(value: str, maximum=100.0) -> float | None:
    try:
        result = float(value)
    except (ValueError, TypeError):
        return None
    return result if math.isfinite(result) and 0.5 <= result <= maximum else None


def building_height(tags: dict) -> tuple[float, int]:
    measured = parse_height(tags.get("height", ""))
    if measured is not None:
        return measured, HEIGHT_MEASURED
    levels = parse_levels(tags.get("building:levels", ""))
    if levels is not None:
        return round(levels * 3.15 + 0.35, 3), HEIGHT_LEVELS
    return HEIGHT_DEFAULTS.get(_source_type(tags), 4.4), HEIGHT_INFERRED


def building_base_offset(tags: dict) -> float:
    minimum_height = parse_length(tags.get("min_height", ""), 0.05, 350.0)
    if minimum_height is not None:
        return round(minimum_height, 3)
    minimum_level = parse_levels(tags.get("building:min_level", ""))
    return round(minimum_level * 3.15, 3) if minimum_level is not None else 0.0


def building_form(tags: dict) -> dict:
    """Keep only source-declared 3D form tags needed for registered massing."""
    result = {}
    if _is_part(tags):
        result["building_part"] = True
        part_type = str(tags.get("building:part", "yes")).strip().lower()
        if part_type and part_type != "yes":
            result["building_part_type"] = part_type
    shape = str(tags.get("roof:shape", "")).strip().lower()
    if shape:
        result["roof_shape"] = shape
    roof_height = parse_length(tags.get("roof:height", ""), 0.05, 100.0)
    if roof_height is not None:
        result["roof_height_m"] = round(roof_height, 3)
    roof_levels = parse_levels(tags.get("roof:levels", ""), 20.0)
    if roof_levels is not None:
        result["roof_levels"] = roof_levels
    orientation = str(tags.get("roof:orientation", "")).strip().lower()
    if orientation in {"along", "across"}:
        result["roof_orientation"] = orientation
    direction = str(tags.get("roof:direction", "")).strip()
    if direction:
        try:
            degrees = float(direction) % 360.0
            if math.isfinite(degrees):
                result["roof_direction_deg"] = round(degrees, 3)
        except (ValueError, TypeError):
            pass
    minimum_height = parse_length(tags.get("min_height", ""), 0.05, 350.0)
    if minimum_height is not None:
        result["min_height_m"] = round(minimum_height, 3)
    minimum_level = parse_levels(tags.get("building:min_level", ""))
    if minimum_level is not None:
        result["min_level"] = minimum_level
    levels = parse_levels(tags.get("building:levels", ""))
    if levels is not None:
        result["levels"] = levels
    return result


def conform_ring(points, sampler, spacing=64.0):
    """Split the base at every terrain grid/diagonal crossing, then sample."""
    result = []
    points = list(points)
    if points[0] != points[-1]:
        points.append(points[0])
    for a, b in zip(points, points[1:]):
        ax, az, bx, bz = a[0], a[1], b[0], b[1]
        values = {0.0}
        for start, finish in [(ax, bx), (az, bz), (ax + az, bx + bz)]:
            if abs(finish - start) < 1e-9:
                continue
            first = math.floor(min(start, finish) / spacing) + 1
            last = math.ceil(max(start, finish) / spacing)
            for line in range(first, last):
                t = (line * spacing - start) / (finish - start)
                if 1e-9 < t < 1.0 - 1e-9:
                    values.add(round(t, 12))
        for t in sorted(values):
            x, z = round(ax + (bx - ax) * t, 4), round(az + (bz - az) * t, 4)
            y = float(sampler(x, z))
            if not math.isfinite(y):
                raise ValueError("Building foundation has non-finite elevation")
            result.append((x, round(y, 5), z))
    return result


def make_record(identifier: str, polygon: Polygon, tags: dict, sampler, cell_size=CELL_SIZE):
    """Return one whole footprint part with courtyard-safe roof triangles."""
    if polygon.is_empty or polygon.area < 1.0:
        raise ValueError("Empty or sub-metre footprint")
    if not polygon.is_valid:
        raise ValueError("Invalid footprint must be repaired before recording")
    from shapely.geometry.polygon import orient
    polygon = orient(polygon, sign=1.0)
    anchor = polygon.representative_point()
    cx, cz = math.floor(anchor.x / cell_size), math.floor(anchor.y / cell_size)
    ox, oz = cx * cell_size, cz * cell_size
    spacing = float(getattr(sampler, "spacing", 64.0))
    rings = [conform_ring(polygon.exterior.coords, sampler, spacing)]
    rings.extend(conform_ring(interior.coords, sampler, spacing) for interior in polygon.interiors)
    height, height_source = building_height(tags)
    roof_y = round(max(p[1] for ring in rings for p in ring) + height, 5)
    vertices, indices, vertex_map = [], [], {}
    triangles = shapely.constrained_delaunay_triangles(polygon)
    for triangle in triangles.geoms:
        if triangle.area <= 1e-8 or not polygon.covers(triangle):
            raise ValueError("Constrained roof triangle crosses a courtyard or exterior")
        tri_indices = []
        for x, z in list(triangle.exterior.coords)[:3]:
            key = (round(x - ox, 4), round(z - oz, 4))
            if key not in vertex_map:
                vertex_map[key] = len(vertices)
                vertices.append(list(key))
            tri_indices.append(vertex_map[key])
        a, b, c = [vertices[i] for i in tri_indices]
        cross = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
        if cross > 0:
            tri_indices[1], tri_indices[2] = tri_indices[2], tri_indices[1]
        indices.extend(tri_indices)
    if not indices:
        raise ValueError("Footprint has no triangulated roof")
    local_rings = [[[round(x - ox, 4), y, round(z - oz, 4)] for x, y, z in ring] for ring in rings]
    kind = KINDS.get(_source_type(tags), 0)
    form = building_form(tags)
    record = [identifier, round(height, 3), height_source, kind, roof_y, local_rings, vertices, indices, form]
    reach = max(math.hypot(x - anchor.x, z - anchor.y) for ring in rings for x, _, z in ring)
    return (cx, cz), record, reach


def split_parent_by_parts(parent: Polygon, part_polygons: list[Polygon]):
    """Remove registered ground-origin building parts from their parent outline."""
    usable = []
    for part in part_polygons:
        if part.is_empty or part.area < 1.0:
            continue
        clipped = parent.intersection(part)
        if not clipped.is_empty and clipped.area >= part.area * 0.8:
            usable.append(clipped)
    if not usable:
        return parent
    remainder = parent.difference(shapely.union_all(usable))
    return shapely.make_valid(remainder) if not remainder.is_valid else remainder


def write_pack(path: Path, cells):
    cells = sorted(cells)
    offset = HEADER.size + len(cells) * INDEX.size
    with path.open("wb") as file:
        file.write(HEADER.pack(MAGIC, len(cells)))
        for x, z, payload in cells:
            if not (0 <= x < TILE_SIZE // CELL_SIZE and 0 <= z < TILE_SIZE // CELL_SIZE):
                raise ValueError("Content cell is outside its tile")
            file.write(INDEX.pack(x, z, offset, len(payload)))
            offset += len(payload)
        for _, _, payload in cells:
            file.write(payload)


def read_cell(path: Path, x: int, z: int):
    with path.open("rb") as file:
        magic, count = HEADER.unpack(file.read(HEADER.size))
        if magic != MAGIC or count > 256:
            raise ValueError("Invalid building tile header")
        file_size = path.stat().st_size
        data_start = HEADER.size + count * INDEX.size
        for _ in range(count):
            cx, cz, offset, length = INDEX.unpack(file.read(INDEX.size))
            if offset < data_start or offset + length > file_size:
                raise ValueError("Invalid building cell index")
            if (cx, cz) == (x, z):
                file.seek(offset)
                return json.loads(gzip.decompress(file.read(length)))
    return []


def compile_dataset(input_path: Path, terrain_root: Path, output: Path, limit=0):
    from build_terrain import TerrainSampler
    sampler = TerrainSampler(terrain_root)
    origin = sampler.manifest["origin"]
    transformer = Transformer.from_crs(4326, 3448, always_xy=True)
    e0, n0 = float(origin["easting"]), float(origin["northing"])
    stats = Counter()
    bounds = [math.inf, math.inf, -math.inf, -math.inf]
    staging = output.with_name(output.name + ".staging")
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True, exist_ok=True)
    database = staging / "footprints.sqlite"
    if database.exists():
        database.unlink()
    connection = sqlite3.connect(database)
    connection.execute("PRAGMA journal_mode=OFF")
    connection.execute("PRAGMA synchronous=OFF")
    connection.execute("PRAGMA cache_size=-16000")
    connection.execute("CREATE TABLE raw (id TEXT PRIMARY KEY,is_part INT,tags TEXT,geometry BLOB,minx REAL,minz REAL,maxx REAL,maxz REAL)")
    connection.execute("CREATE INDEX raw_parts ON raw(is_part)")
    connection.execute("CREATE TABLE records (cx INT,cz INT,id TEXT PRIMARY KEY,digest TEXT UNIQUE,payload TEXT)")
    connection.execute("CREATE INDEX cells ON records(cx,cz,id)")
    factory = osmium.geom.WKBFactory()
    max_reach = 0.0

    def project(x, y, z=None):
        e, n = transformer.transform(x, y)
        try:
            return e - e0, n0 - n
        except TypeError:
            return [v - e0 for v in e], [n0 - v for v in n]

    class Handler(osmium.SimpleHandler):
        def area(self, area):
            tags = dict(area.tags)
            if not _is_building(tags) and not _is_part(tags):
                return
            stats["source_areas"] += 1
            if limit and stats["source_areas"] > limit:
                return
            try:
                geometry = shapely.from_wkb(factory.create_multipolygon(area))
                geometry = transform(project, geometry)
                if not geometry.is_valid:
                    geometry = shapely.make_valid(geometry)
                    stats["repaired_geometries"] += 1
                parts = [g for g in (geometry.geoms if hasattr(geometry, "geoms") else [geometry]) if isinstance(g, Polygon)]
                parts.sort(key=lambda p: (p.bounds, shapely.to_wkb(shapely.normalize(p))))
                source_id = ("w" if area.from_way() else "r") + str(area.orig_id())
                is_part = 1 if _is_part(tags) else 0
                stats["source_building_parts" if is_part else "source_building_outlines"] += 1
                for part_index, polygon in enumerate(parts):
                    if polygon.area < 1.0:
                        stats["tiny_parts"] += 1
                        continue
                    identifier = source_id + ":" + str(part_index)
                    x0, z0, x1, z1 = polygon.bounds
                    connection.execute("INSERT OR IGNORE INTO raw VALUES (?,?,?,?,?,?,?,?)",
                        (identifier, is_part, json.dumps(tags, separators=(",", ":"), sort_keys=True),
                         sqlite3.Binary(shapely.to_wkb(polygon)), x0, z0, x1, z1))
                if stats["source_areas"] % 20000 == 0:
                    connection.commit()
                    print("BUILDING_INGEST", dict(stats), flush=True)
            except Exception as error:
                stats["rejected_areas"] += 1
                reason = "missing_terrain" if "DEM does not cover" in str(error) else "invalid_geometry"
                stats["rejected_" + reason] += 1
                if stats["rejected_areas"] <= 8:
                    print("BUILDING_REJECT", area.orig_id(), type(error).__name__, str(error)[:180], flush=True)

    def polygon_parts(geometry):
        if geometry.is_empty:
            return []
        if isinstance(geometry, Polygon):
            return [geometry]
        return [g for g in getattr(geometry, "geoms", []) if isinstance(g, Polygon) and g.area >= 1.0]

    def emit_geometry(identifier: str, geometry, tags: dict, suffix=""):
        nonlocal max_reach
        emitted = 0
        pieces = polygon_parts(geometry)
        pieces.sort(key=lambda p: (p.bounds, shapely.to_wkb(shapely.normalize(p))))
        for index, polygon in enumerate(pieces):
            if polygon.area < 1.0:
                continue
            record_id = identifier + (suffix + str(index) if suffix else ("" if len(pieces) == 1 else ":g" + str(index)))
            try:
                (cx, cz), record, reach = make_record(record_id, polygon, tags, sampler)
            except ValueError as error:
                if "DEM does not cover" not in str(error):
                    raise
                stats["rejected_geometry_pieces"] += 1
                stats["rejected_missing_terrain"] += 1
                if stats["rejected_geometry_pieces"] <= 8:
                    print("BUILDING_REJECT_PIECE", record_id, type(error).__name__, str(error)[:180], flush=True)
                continue
            normalized = shapely.to_wkb(shapely.normalize(polygon))
            signature = normalized + json.dumps(tags, sort_keys=True, separators=(",", ":")).encode()
            digest = hashlib.sha256(signature).hexdigest()
            result = connection.execute("INSERT OR IGNORE INTO records VALUES (?,?,?,?,?)",
                (cx, cz, record_id, digest, json.dumps(record, separators=(",", ":"), allow_nan=False)))
            if not result.rowcount:
                stats["duplicate_parts"] += 1
                continue
            emitted += 1
            stats["buildings"] += 1
            stats[["", "source_height", "source_levels", "inferred_height"][record[2]]] += 1
            stats["courtyards"] += len(polygon.interiors)
            stats["roof_triangles"] += len(record[7]) // 3
            form = record[8]
            if form.get("roof_shape"):
                stats["source_roof_shape"] += 1
            if form.get("roof_height_m") is not None:
                stats["source_roof_height"] += 1
            if form.get("min_height_m") is not None or form.get("min_level") is not None:
                stats["source_elevated_base"] += 1
            max_reach = max(max_reach, reach)
            x0, z0, x1, z1 = polygon.bounds
            bounds[:] = [min(bounds[0], x0), min(bounds[1], z0), max(bounds[2], x1), max(bounds[3], z1)]
        return emitted

    try:
        Handler().apply_file(str(input_path), locations=True)
        connection.commit()
        if not connection.execute("SELECT 1 FROM raw LIMIT 1").fetchone():
            raise ValueError("No building footprints were compiled")

        # Building parts are far rarer than parent outlines, so only the part
        # set is kept in the bounded spatial lookup. Parent geometry stays on disk.
        part_rows = {}
        part_bins = defaultdict(set)
        for identifier, tags_json, geometry_wkb, minx, minz, maxx, maxz in connection.execute(
                "SELECT id,tags,geometry,minx,minz,maxx,maxz FROM raw WHERE is_part=1 ORDER BY id"):
            tags = json.loads(tags_json)
            geometry = shapely.from_wkb(geometry_wkb)
            base_offset = building_base_offset(tags)
            part_rows[identifier] = {"tags": tags, "geometry": geometry, "area": geometry.area,
                                     "base_offset": base_offset, "ground_origin": base_offset <= 0.001}
            x0, z0 = math.floor(minx / PART_BIN_SIZE), math.floor(minz / PART_BIN_SIZE)
            x1, z1 = math.floor(maxx / PART_BIN_SIZE), math.floor(maxz / PART_BIN_SIZE)
            for bz in range(z0, z1 + 1):
                for bx in range(x0, x1 + 1):
                    part_bins[(bx, bz)].add(identifier)

        def candidate_part_ids(parent):
            minx, minz, maxx, maxz = parent.bounds
            result = set()
            for bz in range(math.floor(minz / PART_BIN_SIZE), math.floor(maxz / PART_BIN_SIZE) + 1):
                for bx in range(math.floor(minx / PART_BIN_SIZE), math.floor(maxx / PART_BIN_SIZE) + 1):
                    result.update(part_bins.get((bx, bz), ()))
            return result

        # Associate every source part to the most specific containing registered
        # outline. Elevated parts need the parent for inheritance but never carve it.
        part_parent = {}
        for parent_id, geometry_wkb in connection.execute(
                "SELECT id,geometry FROM raw WHERE is_part=0 ORDER BY id"):
            parent = shapely.from_wkb(geometry_wkb)
            for part_id in candidate_part_ids(parent):
                part = part_rows[part_id]["geometry"]
                if part.area <= 0.0:
                    continue
                intersection = parent.intersection(part)
                ratio = intersection.area / part.area if not intersection.is_empty else 0.0
                if ratio < 0.8:
                    continue
                score = (ratio, -parent.area)
                if part_id not in part_parent or score > part_parent[part_id][0]:
                    part_parent[part_id] = (score, parent_id)
        stats["parts_associated"] = len(part_parent)

        parent_tag_cache = {}
        def parent_tags(parent_id):
            if parent_id not in parent_tag_cache:
                row = connection.execute("SELECT tags FROM raw WHERE id=?", (parent_id,)).fetchone()
                parent_tag_cache[parent_id] = json.loads(row[0]) if row else {}
            return parent_tag_cache[parent_id]

        ground_parent_parts = defaultdict(list)
        for part_id, info in part_rows.items():
            tags = dict(info["tags"])
            association = part_parent.get(part_id)
            if association is not None:
                parent_id = association[1]
                source_parent_tags = parent_tags(parent_id)
                if not tags.get("height") and not tags.get("building:levels"):
                    if source_parent_tags.get("height"):
                        tags["height"] = source_parent_tags["height"]
                        stats["part_height_inherited"] += 1
                    elif source_parent_tags.get("building:levels"):
                        tags["building:levels"] = source_parent_tags["building:levels"]
                        stats["part_levels_inherited"] += 1
                if info["ground_origin"]:
                    ground_parent_parts[parent_id].append(info["geometry"])

            base_offset = building_base_offset(tags)
            top_height, _ = building_height(tags)
            if base_offset >= top_height - 0.05:
                stats["invalid_elevated_parts"] += 1
                continue
            if emit_geometry(part_id, info["geometry"], tags):
                stats["building_parts_emitted"] += 1
                if base_offset > 0.001:
                    stats["elevated_parts_emitted"] += 1
                else:
                    stats["ground_parts_emitted"] += 1

        # Re-read parents from the SQLite spool for final residual massing.
        for parent_id, tags_json, geometry_wkb in connection.execute(
                "SELECT id,tags,geometry FROM raw WHERE is_part=0 ORDER BY id"):
            tags = json.loads(tags_json)
            parent = shapely.from_wkb(geometry_wkb)
            child_parts = ground_parent_parts.get(parent_id, [])
            geometry = split_parent_by_parts(parent, child_parts) if child_parts else parent
            if child_parts:
                stats["parent_outlines_split"] += 1
                stats["parent_part_area_m2"] += round(parent.area - geometry.area, 3)
            emitted = emit_geometry(parent_id, geometry, tags, ":r" if child_parts else "")
            if child_parts and emitted == 0:
                stats["parent_outlines_fully_replaced"] += 1

        connection.commit()
        if not stats["buildings"]:
            raise ValueError("No building massing records were emitted")

        tiles = []
        current_tile, current_cell, payloads, rows = None, None, [], []
        max_cell_bytes = max_cell_buildings = 0
        cursor = connection.execute("SELECT cx,cz,payload FROM records ORDER BY (cx / 16 - (cx < 0 AND cx % 16 != 0)),(cz / 16 - (cz < 0 AND cz % 16 != 0)),cx,cz,id")

        def finish_cell(cell, records):
            nonlocal max_cell_bytes, max_cell_buildings
            raw = ("[" + ",".join(records) + "]").encode()
            max_cell_bytes = max(max_cell_bytes, len(raw))
            max_cell_buildings = max(max_cell_buildings, len(records))
            if len(raw) > 32 * 1024 * 1024:
                raise ValueError("Building cell exceeds the 32 MiB safety bound")
            payloads.append((cell[0] % 16, cell[1] % 16, gzip.compress(raw, compresslevel=6, mtime=0)))

        def finish_tile(tile):
            filename = f"buildings_{tile[0]}_{tile[1]}.ymb"
            write_pack(staging / filename, payloads)
            tiles.append({"x": tile[0], "z": tile[1], "file": filename, "cells": [[x, z] for x, z, _ in sorted(payloads)]})

        for cx, cz, payload in cursor:
            tile, cell = (cx // 16, cz // 16), (cx, cz)
            if current_cell is not None and cell != current_cell:
                finish_cell(current_cell, rows)
                rows = []
            if current_tile is not None and tile != current_tile:
                finish_tile(current_tile)
                payloads = []
            current_tile, current_cell = tile, cell
            rows.append(payload)
        if current_cell is not None:
            finish_cell(current_cell, rows)
            finish_tile(current_tile)
        stats["tiles"], stats["cells"] = len(tiles), sum(len(t["cells"]) for t in tiles)
        manifest = {"format": 1, "record_format": 2,
                    "encoding": "YMB1: <4sI> header, <HHII> local cell x/z, byte offset/length, deterministic gzip JSON arrays",
                    "record": "[OSM mass id,height metres,height source(1=tag,2=levels,3=inferred),kind,maximum building elevation,rings[[x,y,z]],roof vertices[[x,z]],roof triangle indices,source form metadata]",
                    "coordinates": "X/Z relative to owning 256m content cell; Y canonical metres EGM2008",
                    "crs": "EPSG:3448", "origin": origin, "tile_size": TILE_SIZE, "cell_size": CELL_SIZE,
                    "source": "OpenStreetMap / Geofabrik Jamaica extract",
                    "source_sha256": hashlib.file_digest(input_path.open("rb"), "sha256").hexdigest(),
                    "attribution": "© OpenStreetMap contributors — https://www.openstreetmap.org/copyright (ODbL)",
                    "terrain_attribution": sampler.manifest.get("attribution", ""),
                    "height_inference": "Source height > source building:levels × 3.15m + 0.35m > declared class estimate (default 4.4m). Maximum massing elevation is above maximum sampled foundation height. DSM foundations are not surveyed bare-earth levels.",
                    "massing": "Ground-origin building:part polygons replace overlapping parent volume. Elevated parts use source min_height/building:min_level and remain stacked above the parent; they never carve away the lower parent mass. Invalid stacks whose base reaches/exceeds their top are rejected.",
                    "appearance": "Registered footprint and source 3D form metadata are preserved. Unsupported source forms remain conservative extrusions until runtime support exists; presentation inference is explicitly separate from source truth.",
                    "bounds": [round(v, 3) for v in bounds], "max_footprint_reach_m": round(max_reach, 3),
                    "max_cell_uncompressed_bytes": max_cell_bytes, "max_cell_buildings": max_cell_buildings,
                    "stats": dict(stats), "tiles": tiles}
        (staging / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True))
    finally:
        connection.close()
    database.unlink(missing_ok=True)
    for scratch in staging.glob(".footprints.sqlite.*"):
        scratch.unlink()
    if output.exists():
        shutil.rmtree(output)
    staging.replace(output)
    return manifest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("terrain", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--limit", type=int, default=0, help="Debug ingestion cap; zero compiles national data")
    args = parser.parse_args()
    manifest = compile_dataset(args.input, args.terrain, args.output, args.limit)
    print("YARDMAN_BUILDINGS_COMPILE_PASS", json.dumps(manifest["stats"], sort_keys=True), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())