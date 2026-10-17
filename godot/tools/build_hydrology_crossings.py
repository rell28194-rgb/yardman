#!/usr/bin/env python3
"""Classify road/waterway crossings without inventing structures.

The compiler reads the same Jamaica OSM source used by the road and hydrology
pipelines, projects both feature families into the Yardman metre grid, and
records geometric crossings. Source tags decide whether a crossing is a bridge,
culvert/underground waterway, road tunnel, ford or explicit layer separation.
Anything not established by source evidence remains unresolved.

This is intentionally an evidence compiler, not an auto-bridge generator.
"""
from __future__ import annotations

import argparse
import json
import math
import shutil
from collections import Counter, defaultdict
from pathlib import Path

from build_hydrology import WATERWAY_CLASSES, parse_bool_tag, parse_layer, waterway_structure

# Kept dependency-light on purpose: the pure classification contract must be
# importable by core CI without installing GIS libraries. This set mirrors the
# production road compiler's accepted drivable highway classes.
DRIVABLE_HIGHWAYS = {
    "motorway", "motorway_link", "trunk", "trunk_link", "primary", "primary_link",
    "secondary", "secondary_link", "tertiary", "tertiary_link", "unclassified",
    "residential", "living_street", "service", "road", "track", "raceway",
}
FALSE_TAGS = {"", "no", "false", "0"}


def active_structure_tag(raw) -> bool:
    return str(raw or "").strip().lower() not in FALSE_TAGS


def classify_crossing(road_tags: dict, water_tags: dict, shared_osm_node: bool) -> tuple[str, str, bool]:
    """Return classification, evidence reason, and whether resolution is final.

    `final` means source data already states enough to prevent terrain generation
    from making the opposite interpretation. It does not claim that a detailed
    structural model has already been reconstructed.
    """
    water = waterway_structure(water_tags)
    road_layer = parse_layer(road_tags.get("layer"))
    water_layer = water["layer"]
    road_bridge = active_structure_tag(road_tags.get("bridge"))
    road_tunnel = active_structure_tag(road_tags.get("tunnel"))
    ford = parse_bool_tag(road_tags.get("ford")) or str(road_tags.get("highway", "")).lower() == "ford"

    if water["culvert"]:
        return "waterway_culvert", "source waterway tunnel=culvert/culvert=yes", True
    if water["underground"]:
        return "waterway_underground", "source waterway covered/tunnel/location=underground", True
    if road_bridge:
        return "road_bridge", "source road bridge tag", True
    if road_tunnel:
        return "road_tunnel", "source road tunnel tag", True
    if ford:
        return "ford", "source road ford tag", True
    if road_layer != water_layer:
        relation = "road_over_waterway" if road_layer > water_layer else "road_under_waterway"
        return "layer_grade_separation", f"source layer relation: {relation}", False
    if shared_osm_node:
        return "at_grade_shared_node_unresolved", "shared OSM node without bridge/culvert/ford evidence", False
    return "geometric_crossing_unresolved", "planar geometry intersection without structure evidence", False


def _point_components(geometry):
    kind = geometry.geom_type
    if kind == "Point":
        yield geometry
    elif kind == "MultiPoint":
        yield from geometry.geoms
    elif kind == "GeometryCollection":
        for part in geometry.geoms:
            yield from _point_components(part)


def compile_crossings(osm_pbf: Path, hydrology_root: Path, output_root: Path) -> dict:
    try:
        import osmium
        from pyproj import Transformer
        from shapely.geometry import LineString
        from shapely.strtree import STRtree
    except ImportError as exc:  # pragma: no cover - workflow dependency gate
        raise RuntimeError("build_hydrology_crossings requires osmium, pyproj and shapely") from exc

    hydrology_manifest = json.loads((hydrology_root / "manifest.json").read_text(encoding="utf-8"))
    tile_size = float(hydrology_manifest["tile_size"])
    origin = hydrology_manifest["origin"]
    e0, n0 = float(origin["easting"]), float(origin["northing"])
    project = Transformer.from_crs(4326, 3448, always_xy=True)

    roads = []
    waters = []

    class Handler(osmium.SimpleHandler):
        def way(self, way) -> None:
            highway = str(way.tags.get("highway", ""))
            waterway = str(way.tags.get("waterway", ""))
            if highway not in DRIVABLE_HIGHWAYS and waterway not in WATERWAY_CLASSES:
                return
            nodes = []
            for node in way.nodes:
                try:
                    if not node.location.valid():
                        continue
                    easting, northing = project.transform(node.location.lon, node.location.lat)
                except Exception:
                    continue
                nodes.append((float(easting) - e0, n0 - float(northing), int(node.ref)))
            if len(nodes) < 2:
                return
            record = {"id": f"w{int(way.id)}", "tags": dict(way.tags), "nodes": nodes}
            if highway in DRIVABLE_HIGHWAYS:
                roads.append(record)
            if waterway in WATERWAY_CLASSES:
                waters.append(record)

    Handler().apply_file(str(osm_pbf), locations=True)

    road_lines = [LineString([(p[0], p[1]) for p in record["nodes"]]) for record in roads]
    road_tree = STRtree(road_lines)
    records_by_tile = defaultdict(list)
    stats = Counter()
    seen = set()

    for water_record in waters:
        water_line = LineString([(p[0], p[1]) for p in water_record["nodes"]])
        if water_line.is_empty or water_line.length <= 1e-6:
            continue
        water_node_positions = {node[2]: (node[0], node[1]) for node in water_record["nodes"]}
        for candidate_index in road_tree.query(water_line):
            road_index = int(candidate_index)
            road_record = roads[road_index]
            road_line = road_lines[road_index]
            if not road_line.intersects(water_line):
                continue
            intersection = road_line.intersection(water_line)
            if intersection.is_empty:
                continue
            common_nodes = set(water_node_positions).intersection(node[2] for node in road_record["nodes"])
            common_positions = {
                node[2]: (node[0], node[1]) for node in road_record["nodes"] if node[2] in common_nodes
            }

            points = list(_point_components(intersection))
            overlap = False
            if not points and intersection.geom_type in {"LineString", "MultiLineString"}:
                points = [intersection.representative_point()]
                overlap = True

            for point in points:
                x, z = float(point.x), float(point.y)
                shared_node = False
                shared_node_id = None
                for node_id in common_nodes:
                    px, pz = common_positions[node_id]
                    if math.hypot(px - x, pz - z) <= 0.75:
                        shared_node = True
                        shared_node_id = int(node_id)
                        break

                if overlap:
                    classification, reason, final = (
                        "linear_overlap_unresolved",
                        "road and waterway overlap geometrically; requires local source review",
                        False,
                    )
                else:
                    classification, reason, final = classify_crossing(
                        road_record["tags"], water_record["tags"], shared_node
                    )

                key = (
                    road_record["id"], water_record["id"], classification,
                    round(x, 2), round(z, 2),
                )
                if key in seen:
                    continue
                seen.add(key)
                tx, tz = math.floor(x / tile_size), math.floor(z / tile_size)
                road_tags = road_record["tags"]
                water_tags = water_record["tags"]
                record = {
                    "x": round(x, 3), "z": round(z, 3),
                    "road_way": road_record["id"], "waterway_way": water_record["id"],
                    "waterway": str(water_tags.get("waterway", "")),
                    "water_name": str(water_tags.get("name", "")),
                    "road_class": str(road_tags.get("highway", "")),
                    "road_name": str(road_tags.get("name", "")),
                    "road_ref": str(road_tags.get("ref", "")),
                    "classification": classification, "reason": reason,
                    "resolved_by_source": final,
                    "shared_osm_node": shared_node, "shared_node_id": shared_node_id,
                    "road_bridge": str(road_tags.get("bridge", "")),
                    "road_tunnel": str(road_tags.get("tunnel", "")),
                    "road_ford": str(road_tags.get("ford", "")),
                    "road_layer": parse_layer(road_tags.get("layer")),
                    "water_tunnel": str(water_tags.get("tunnel", "")),
                    "water_culvert": str(water_tags.get("culvert", "")),
                    "water_layer": parse_layer(water_tags.get("layer")),
                    "water_covered": str(water_tags.get("covered", "")),
                    "water_location": str(water_tags.get("location", "")),
                }
                records_by_tile[(tx, tz)].append(record)
                stats["crossings"] += 1
                stats[f"classification_{classification}"] += 1
                stats["resolved_by_source" if final else "requires_resolution"] += 1
                if shared_node:
                    stats["shared_node_crossings"] += 1

    staging = output_root.with_name(output_root.name + ".staging")
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    tiles = []
    for (tx, tz), values in sorted(records_by_tile.items()):
        values.sort(key=lambda item: (item["waterway_way"], item["road_way"], item["x"], item["z"]))
        filename = f"tile_{tx}_{tz}.json"
        (staging / filename).write_text(
            json.dumps({"tile": [tx, tz], "crossings": values}, separators=(",", ":")),
            encoding="utf-8",
        )
        tiles.append({"x": tx, "z": tz, "file": filename, "crossings": len(values)})

    manifest = {
        "format": 1,
        "source": "OpenStreetMap road/waterway crossing evidence",
        "classification_policy": "source tags first; ambiguous crossings remain unresolved",
        "stats": dict(sorted(stats.items())),
        "tiles": tiles,
    }
    (staging / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True), encoding="utf-8")
    if output_root.exists():
        shutil.rmtree(output_root)
    staging.replace(output_root)
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("osm_pbf", type=Path)
    parser.add_argument("hydrology_root", type=Path)
    parser.add_argument("output_root", type=Path)
    args = parser.parse_args()
    manifest = compile_crossings(args.osm_pbf, args.hydrology_root, args.output_root)
    print("YARDMAN_HYDROLOGY_CROSSINGS_PASS", json.dumps(manifest["stats"], sort_keys=True),
          "tiles=", len(manifest["tiles"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
