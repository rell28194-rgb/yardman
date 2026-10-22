#!/usr/bin/env python3
"""Build a conservative national inventory of registered road/water crossings.

Geometry finds candidate intersections only. Structural classification is delegated
to hydrology_crossings, so an intersection cannot invent a bridge, culvert, ford,
or DEM mutation. Road bridge/tunnel/layer semantics come from the persistent road
graph. Optional direct OSM evidence recovers explicit ford nodes/way tags and
waterway ``tunnel=culvert`` semantics that the render graph does not need to retain.
Water identity and geometry come from the compiled hydrology truth pack.
"""
from __future__ import annotations

import argparse
import json
import math
from collections import Counter
from pathlib import Path

from hydrology_crossings import classify_crossing


_POSITIVE_VALUES = {"yes", "true", "1", "ford", "culvert"}


def _load_edges(roads: Path) -> list[dict]:
    edges = []
    for path in sorted((roads / "graph").glob("edges_*.json")):
        edges.extend(json.loads(path.read_text(encoding="utf-8")).values())
    return edges


def _load_water(hydrology: Path) -> list[dict]:
    manifest = json.loads((hydrology / "manifest.json").read_text(encoding="utf-8"))
    fields = manifest["record_format"]
    result = []
    for tile in manifest["tiles"]:
        payload = json.loads((hydrology / tile["file"]).read_text(encoding="utf-8"))
        for raw in payload.get("segments", []):
            result.append(dict(zip(fields, raw)))
    return result


def _positive_value(value: object) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return False
    return str(value).strip().lower() in _POSITIVE_VALUES


def _source_bool(edge: dict, *keys: str) -> bool:
    """Read only explicit positive source evidence; absence/``no`` stay false."""
    return any(_positive_value(edge.get(key)) for key in keys)


def _source_tags(tags) -> dict[str, str]:
    result: dict[str, str] = {}
    for key in ("ford", "culvert", "tunnel", "bridge", "highway", "waterway"):
        value = tags.get(key)
        if value is not None:
            result[key] = str(value).strip().lower()
    return result


def _load_osm_crossing_evidence(osm_pbf: Path | None, roads: Path) -> dict:
    """Load only explicit crossing semantics from the same OSM source.

    The road renderer intentionally drops many raw OSM tags. This evidence join is
    separate so presentation simplification cannot erase source truth. Tagged ford
    nodes are transformed into the accepted Yardman grid and later require both
    road-way membership and tight spatial agreement with the registered crossing.
    """
    empty = {"road_tags": {}, "water_tags": {}, "road_ford_nodes": {}}
    if osm_pbf is None:
        return empty
    if not osm_pbf.is_file():
        raise ValueError(f"OSM crossing evidence source missing: {osm_pbf}")
    try:
        import osmium
        from pyproj import Transformer
    except ImportError as exc:
        raise RuntimeError("OSM crossing evidence requires osmium and pyproj") from exc

    manifest = json.loads((roads / "manifest.json").read_text(encoding="utf-8"))
    if str(manifest.get("crs", "")) != "EPSG:3448":
        raise ValueError("road crossing evidence requires EPSG:3448 road data")
    origin = manifest.get("origin", {})
    e0 = float(origin["easting"])
    n0 = float(origin["northing"])
    project = Transformer.from_crs("EPSG:4326", "EPSG:3448", always_xy=True)

    road_tags: dict[str, dict[str, str]] = {}
    water_tags: dict[str, dict[str, str]] = {}
    road_nodes: dict[str, set[int]] = {}
    ford_nodes: dict[int, tuple[float, float]] = {}

    class Handler(osmium.SimpleHandler):
        def node(self, node) -> None:
            if not (_positive_value(node.tags.get("ford")) or str(node.tags.get("highway", "")).strip().lower() == "ford"):
                return
            try:
                if not node.location.valid():
                    return
                easting, northing = project.transform(node.location.lon, node.location.lat)
            except Exception:
                return
            x = float(easting) - e0
            z = n0 - float(northing)
            if math.isfinite(x) and math.isfinite(z):
                ford_nodes[int(node.id)] = (x, z)

        def way(self, way) -> None:
            source_id = f"w{int(way.id)}"
            if "highway" in way.tags:
                road_tags[source_id] = _source_tags(way.tags)
                road_nodes[source_id] = {int(node.ref) for node in way.nodes}
            if "waterway" in way.tags:
                water_tags[source_id] = _source_tags(way.tags)

    Handler().apply_file(str(osm_pbf), locations=True)
    road_ford_nodes: dict[str, list[tuple[int, float, float]]] = {}
    tagged_refs = set(ford_nodes)
    for source_id, refs in road_nodes.items():
        matches = refs & tagged_refs
        if matches:
            road_ford_nodes[source_id] = [(ref, ford_nodes[ref][0], ford_nodes[ref][1]) for ref in sorted(matches)]
    return {"road_tags": road_tags, "water_tags": water_tags, "road_ford_nodes": road_ford_nodes}


def _ford_evidence(source: dict, road_source_way: str, water_source_way: str,
                   x: float, z: float, tolerance_m: float = 6.0) -> tuple[bool, str]:
    road_tags = source["road_tags"].get(road_source_way, {})
    water_tags = source["water_tags"].get(water_source_way, {})
    if _positive_value(road_tags.get("ford")):
        return True, "osm:road_way_ford"
    if _positive_value(water_tags.get("ford")):
        return True, "osm:water_way_ford"
    tolerance_sq = tolerance_m * tolerance_m
    for node_ref, nx, nz in source["road_ford_nodes"].get(road_source_way, []):
        if (nx - x) * (nx - x) + (nz - z) * (nz - z) <= tolerance_sq:
            return True, f"osm:ford_node={node_ref}"
    return False, ""


def _culvert_evidence(source: dict, road_source_way: str, water_source_way: str) -> tuple[bool, str]:
    road_tags = source["road_tags"].get(road_source_way, {})
    water_tags = source["water_tags"].get(water_source_way, {})
    if _positive_value(road_tags.get("culvert")):
        return True, "osm:road_way_culvert"
    if _positive_value(water_tags.get("culvert")):
        return True, "osm:water_way_culvert"
    if str(water_tags.get("tunnel", "")).strip().lower() == "culvert":
        return True, "osm:waterway_tunnel=culvert"
    return False, ""


def build_inventory(roads: Path, hydrology: Path, output: Path, osm_pbf: Path | None = None) -> dict:
    try:
        from shapely.geometry import LineString
        from shapely.strtree import STRtree
    except ImportError as exc:
        raise RuntimeError("build_hydrology_crossings requires shapely>=2.1") from exc

    edges = _load_edges(roads)
    water = _load_water(hydrology)
    source_evidence = _load_osm_crossing_evidence(osm_pbf, roads)
    road_geoms, road_records = [], []
    for edge in edges:
        path = edge.get("path") or []
        if len(path) < 2:
            continue
        geom = LineString([(float(p[0]), float(p[2])) for p in path])
        if geom.length <= 0:
            continue
        road_geoms.append(geom)
        road_records.append(edge)
    tree = STRtree(road_geoms)
    records, stats = [], Counter()
    seen = set()
    for water_record in water:
        water_geom = LineString([(water_record["ax"], water_record["az"]),
                                 (water_record["bx"], water_record["bz"])])
        for index in tree.query(water_geom, predicate="intersects"):
            edge = road_records[int(index)]
            intersection = water_geom.intersection(road_geoms[int(index)])
            if intersection.is_empty:
                continue
            point = intersection.representative_point()
            key = (edge["id"], water_record["source_way"], round(point.x, 3), round(point.y, 3))
            if key in seen:
                continue
            seen.add(key)
            # Never use Python truthiness for source tags: strings such as
            # ``bridge=no`` and ``tunnel=no`` are truthy and would otherwise
            # fabricate approved grade separation at real road/water crossings.
            road_bridge = _source_bool(edge, "bridge", "osm_bridge", "source_bridge")
            road_tunnel = _source_bool(edge, "tunnel", "osm_tunnel", "source_tunnel")
            road_source_way = str(edge.get("source_way", ""))
            water_source_way = str(water_record["source_way"])
            graph_ford = _source_bool(edge, "ford", "osm_ford", "source_ford")
            graph_culvert = _source_bool(edge, "culvert", "osm_culvert", "source_culvert")
            osm_ford, ford_source = _ford_evidence(source_evidence, road_source_way, water_source_way,
                                                    float(point.x), float(point.y))
            osm_culvert, culvert_source = _culvert_evidence(source_evidence, road_source_way, water_source_way)
            explicit_ford = graph_ford or osm_ford
            explicit_culvert = graph_culvert or osm_culvert
            engineered_drain = _source_bool(edge, "engineered_drain_record", "authoritative_engineered_drain")
            decision = classify_crossing(road_bridge=road_bridge,
                                         road_tunnel=road_tunnel,
                                         road_layer=edge.get("layer", 0),
                                         explicit_ford=explicit_ford,
                                         explicit_culvert=explicit_culvert,
                                         engineered_drain_record=engineered_drain)
            record = {"x": round(point.x, 3), "z": round(point.y, 3),
                      "road_edge": edge["id"], "road_source_way": road_source_way,
                      "water_source_way": water_source_way,
                      "waterway": water_record["waterway"], "water_name": water_record.get("name", ""),
                      "source_crossing_evidence": {"bridge": road_bridge, "tunnel": road_tunnel,
                                                   "ford": explicit_ford, "culvert": explicit_culvert,
                                                   "ford_source": ford_source,
                                                   "culvert_source": culvert_source,
                                                   "engineered_drain": engineered_drain},
                      **decision.to_dict()}
            records.append(record)
            stats["crossings"] += 1
            stats[f"kind_{decision.kind}"] += 1
            stats[f"status_{decision.status}"] += 1
            stats[f"waterway_{water_record['waterway']}"] += 1
            if road_bridge:
                stats["evidence_bridge"] += 1
            if road_tunnel:
                stats["evidence_tunnel"] += 1
            if explicit_ford:
                stats["evidence_ford"] += 1
                if ford_source:
                    stats[ford_source.split("=")[0].replace(":", "_")] += 1
            if explicit_culvert:
                stats["evidence_culvert"] += 1
                if culvert_source:
                    stats[culvert_source.replace("=", "_").replace(":", "_")] += 1
            if engineered_drain:
                stats["evidence_engineered_drain"] += 1
    records.sort(key=lambda r: (r["road_edge"], r["water_source_way"], r["x"], r["z"]))
    output.parent.mkdir(parents=True, exist_ok=True)
    payload = {"format": 4,
               "geometry_status": "registered geometric intersections; structures only where explicit positive source evidence supports classification",
               "source_evidence_status": "road graph plus optional direct OSM ford/culvert join; tagged ford nodes require road membership and <=6 m crossing agreement",
               "terrain_mutation_policy": "unresolved crossings authorize no destructive DEM mutation",
               "stats": dict(sorted(stats.items())), "crossings": records}
    output.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    return payload


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("roads", type=Path)
    parser.add_argument("hydrology", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--osm-pbf", type=Path, default=None,
                        help="Optional exact OSM source used to recover explicit ford/culvert semantics")
    args = parser.parse_args()
    result = build_inventory(args.roads, args.hydrology, args.output, args.osm_pbf)
    print(json.dumps(result["stats"], sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
