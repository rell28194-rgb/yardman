#!/usr/bin/env python3
"""Build a conservative national inventory of registered road/water crossings.

Geometry finds candidate intersections only. Structural classification is delegated
to hydrology_crossings, so an intersection cannot invent a bridge, culvert, ford,
or DEM mutation. Road bridge/tunnel/layer semantics and any explicit ford/culvert
provenance come from the persistent OSM road graph; water identity and geometry
come from the compiled hydrology truth pack.
"""
from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path

from hydrology_crossings import classify_crossing


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


def _source_bool(edge: dict, *keys: str) -> bool:
    """Read only explicit source evidence; absence never becomes inference."""
    for key in keys:
        value = edge.get(key)
        if isinstance(value, bool):
            if value:
                return True
            continue
        if value is None:
            continue
        if str(value).strip().lower() in {"yes", "true", "1", "ford", "culvert"}:
            return True
    return False


def build_inventory(roads: Path, hydrology: Path, output: Path) -> dict:
    try:
        from shapely.geometry import LineString
        from shapely.strtree import STRtree
    except ImportError as exc:
        raise RuntimeError("build_hydrology_crossings requires shapely>=2.1") from exc

    edges = _load_edges(roads)
    water = _load_water(hydrology)
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
            explicit_ford = _source_bool(edge, "ford", "osm_ford", "source_ford")
            explicit_culvert = _source_bool(edge, "culvert", "osm_culvert", "source_culvert")
            engineered_drain = _source_bool(edge, "engineered_drain_record", "authoritative_engineered_drain")
            decision = classify_crossing(road_bridge=bool(edge.get("bridge")),
                                         road_tunnel=bool(edge.get("tunnel")),
                                         road_layer=edge.get("layer", 0),
                                         explicit_ford=explicit_ford,
                                         explicit_culvert=explicit_culvert,
                                         engineered_drain_record=engineered_drain)
            record = {"x": round(point.x, 3), "z": round(point.y, 3),
                      "road_edge": edge["id"], "road_source_way": edge.get("source_way"),
                      "water_source_way": water_record["source_way"],
                      "waterway": water_record["waterway"], "water_name": water_record.get("name", ""),
                      "source_crossing_evidence": {"ford": explicit_ford, "culvert": explicit_culvert,
                                                   "engineered_drain": engineered_drain},
                      **decision.to_dict()}
            records.append(record)
            stats["crossings"] += 1
            stats[f"kind_{decision.kind}"] += 1
            stats[f"status_{decision.status}"] += 1
            stats[f"waterway_{water_record['waterway']}"] += 1
            if explicit_ford:
                stats["evidence_ford"] += 1
            if explicit_culvert:
                stats["evidence_culvert"] += 1
            if engineered_drain:
                stats["evidence_engineered_drain"] += 1
    records.sort(key=lambda r: (r["road_edge"], r["water_source_way"], r["x"], r["z"]))
    output.parent.mkdir(parents=True, exist_ok=True)
    payload = {"format": 2,
               "geometry_status": "registered geometric intersections; structures only where explicit source evidence supports classification",
               "terrain_mutation_policy": "unresolved crossings authorize no destructive DEM mutation",
               "stats": dict(sorted(stats.items())), "crossings": records}
    output.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    return payload


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("roads", type=Path)
    parser.add_argument("hydrology", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    result = build_inventory(args.roads, args.hydrology, args.output)
    print(json.dumps(result["stats"], sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
