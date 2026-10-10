#!/usr/bin/env python3
"""Compile outer tunnel portals from the profiled national road graph.

Graph edges can split one OSM tunnel way at internal nodes. A portal must only
exist at a degree-one endpoint within that source tunnel way; otherwise every
edge split would punch a fake opening through the mountain.
"""
from __future__ import annotations

import argparse
import json
import math
import shutil
from collections import Counter, defaultdict
from pathlib import Path


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("roads_root", type=Path)
    return p.parse_args()


def _load_edges(root: Path) -> dict:
    result = {}
    for path in sorted((root / "graph").glob("edges_*.json")):
        payload = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(payload, dict):
            raise ValueError(f"Invalid graph partition {path}")
        overlap = set(result).intersection(payload)
        if overlap:
            raise ValueError(f"Duplicate graph edge identifiers: {sorted(overlap)[:3]}")
        result.update(payload)
    if not result:
        raise ValueError("No graph edges found")
    return result


def _layer(edge: dict) -> int:
    try:
        return int(str(edge.get("layer", "0")))
    except ValueError:
        return 0


def _point(edge: dict, node_id: str):
    path = edge.get("path") or []
    if len(path) < 2:
        raise ValueError(f"Tunnel edge {edge.get('id')} has no portal direction")
    if str(edge.get("from")) == node_id:
        return path[0], path[1], "start"
    if str(edge.get("to")) == node_id:
        return path[-1], path[-2], "end"
    raise ValueError(f"Node {node_id} is not an endpoint of {edge.get('id')}")


def compile_portals(roads_root: Path) -> dict:
    manifest = json.loads((roads_root / "manifest.json").read_text(encoding="utf-8"))
    tile_size = float(manifest["tile_size"])
    edges = _load_edges(roads_root)
    by_way = defaultdict(list)
    for edge in edges.values():
        if edge.get("tunnel") and _layer(edge) < 0:
            by_way[str(edge.get("source_way", edge.get("id")))].append(edge)

    portals_by_tile = defaultdict(list)
    anomalies = []
    source_way_counts = {}
    total_portals = 0
    for source_way in sorted(by_way):
        way_edges = by_way[source_way]
        endpoint_counts = Counter()
        endpoint_edge = {}
        for edge in way_edges:
            for node_id in (str(edge.get("from")), str(edge.get("to"))):
                endpoint_counts[node_id] += 1
                endpoint_edge.setdefault(node_id, edge)
        outer = sorted(node_id for node_id, count in endpoint_counts.items() if count == 1)
        source_way_counts[source_way] = {"edges": len(way_edges), "outer_endpoints": len(outer)}
        if len(outer) != 2:
            anomalies.append({"source_way": source_way, "edges": len(way_edges), "outer_endpoints": outer})
        for node_id in outer:
            edge = endpoint_edge[node_id]
            position, toward, side = _point(edge, node_id)
            px, py, pz = map(float, position[:3])
            tx, tz = math.floor(px / tile_size), math.floor(pz / tile_size)
            portal = {
                "source_way": source_way,
                "edge_id": str(edge.get("id")),
                "node_id": node_id,
                "side": side,
                "position": [px, py, pz],
                "toward": [float(toward[0]), float(toward[1]), float(toward[2])],
                "width_m": float(edge.get("width_m", 6.0) or 6.0),
                "layer": _layer(edge),
            }
            portals_by_tile[(tx, tz)].append(portal)
            total_portals += 1

    output = roads_root / "tunnel_portals"
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    tile_records = []
    for tx, tz in sorted(portals_by_tile):
        portals = sorted(portals_by_tile[(tx, tz)], key=lambda p: (p["source_way"], p["node_id"]))
        filename = f"tile_{tx}_{tz}.json"
        (output / filename).write_text(
            json.dumps({"tile": [tx, tz], "portals": portals}, separators=(",", ":")), encoding="utf-8")
        tile_records.append({"x": tx, "z": tz, "file": filename, "portals": len(portals)})

    result = {
        "format": 1,
        "tile_size": tile_size,
        "profiled_tunnel_source_ways": len(by_way),
        "portals": total_portals,
        "tiles": tile_records,
        "anomalies": anomalies,
        "source_way_counts": source_way_counts,
    }
    (output / "manifest.json").write_text(json.dumps(result, indent=2, sort_keys=True), encoding="utf-8")
    return result


def main() -> int:
    args = parse_args()
    result = compile_portals(args.roads_root)
    print("YARDMAN_TUNNEL_PORTALS_PASS", json.dumps({
        "source_ways": result["profiled_tunnel_source_ways"],
        "portals": result["portals"],
        "tiles": len(result["tiles"]),
        "anomalies": len(result["anomalies"]),
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
