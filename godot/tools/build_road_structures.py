#!/usr/bin/env python3
"""Build terrain-independent road structures after DEM road conformance.

OSM bridge centre-lines are initially sampled against the DEM so their
abutments register perfectly with ordinary roads. This pass keeps those
abutment elevations but replaces the interior bridge deck with a continuous
linear profile. The bridge ribbon is therefore no longer draped into the
river/valley/road underneath it. Tunnels are counted but deliberately left
untouched until a terrain-corridor/portal mesh is present; lowering them without
carving terrain would make them less driveable, not more correct.
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

PROFILE_SOURCE = "DEM abutments + terrain-independent bridge deck"


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("roads_root", type=Path)
    return p.parse_args()


def _graph_files(root: Path, kind: str):
    files = sorted((root / "graph").glob(f"{kind}_*.json"))
    if not files:
        raise ValueError(f"No {kind} partitions under {root / 'graph'}")
    return files


def _load_edges(root: Path):
    edges, owners = {}, {}
    for path in _graph_files(root, "edges"):
        payload = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(payload, dict):
            raise ValueError(f"Invalid graph partition: {path}")
        for edge_id, edge in payload.items():
            if edge_id in edges:
                raise ValueError(f"Duplicate edge id {edge_id}")
            edges[edge_id] = edge
            owners[edge_id] = path
    return edges, owners


def _horizontal_stations(path):
    stations = [0.0]
    for a, b in zip(path, path[1:]):
        stations.append(stations[-1] + math.hypot(float(b[0]) - float(a[0]), float(b[2]) - float(a[2])))
    return stations


def _bridge_profile(edge: dict):
    path = edge.get("path") or []
    if len(path) < 2:
        raise ValueError(f"Bridge edge {edge.get('id')} has no usable path")
    stations = _horizontal_stations(path)
    total = stations[-1]
    if total <= 1e-6:
        raise ValueError(f"Bridge edge {edge.get('id')} has zero horizontal length")
    start_y, end_y = float(path[0][1]), float(path[-1][1])
    original = [float(p[1]) for p in path]
    adjusted = []
    maximum_delta = 0.0
    for index, point in enumerate(path):
        t = stations[index] / total
        y = start_y + (end_y - start_y) * t
        maximum_delta = max(maximum_delta, abs(y - original[index]))
        adjusted.append([float(point[0]), round(y, 6), float(point[2])])
    return adjusted, maximum_delta


def _profile_y(start_y: float, end_y: float, start_station: float, end_station: float, station: float):
    span = end_station - start_station
    if abs(span) <= 1e-9:
        return start_y
    t = max(0.0, min(1.0, (station - start_station) / span))
    return start_y + (end_y - start_y) * t


def compile_structures(roads_root: Path) -> dict:
    manifest_path = roads_root / "manifest.json"
    if not manifest_path.is_file():
        raise ValueError(f"Missing roads manifest: {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    edges, owners = _load_edges(roads_root)

    prior_summary = {}
    summary_path = roads_root / "structures.json"
    if summary_path.is_file():
        try:
            prior_summary = json.loads(summary_path.read_text(encoding="utf-8"))
        except (ValueError, OSError):
            prior_summary = {}
    already_profiled = bool(edges) and all(
        not edge.get("bridge") or edge.get("elevation_source") == PROFILE_SOURCE
        for edge in edges.values()
    )

    bridge_profiles = {}
    original_endpoints = {}
    bridge_length = 0.0
    tunnel_length = 0.0
    tunnel_edges = 0
    max_vertical_correction = 0.0
    by_class = {}

    for edge_id, edge in edges.items():
        if edge.get("tunnel"):
            tunnel_edges += 1
            tunnel_length += float(edge.get("length_m", 0.0) or 0.0)
        if not edge.get("bridge"):
            continue
        path = edge.get("path") or []
        if len(path) < 2:
            continue
        original_endpoints[edge_id] = (float(path[0][1]), float(path[-1][1]))
        profile, correction = _bridge_profile(edge)
        bridge_profiles[edge_id] = profile
        edge["path"] = profile
        edge["elevation_source"] = PROFILE_SOURCE
        bridge_length += float(edge.get("length_m", 0.0) or 0.0)
        max_vertical_correction = max(max_vertical_correction, correction)
        klass = str(edge.get("class", "unknown"))
        by_class[klass] = by_class.get(klass, 0) + 1

    # If this exact generated dataset has already passed once, preserve the
    # measured amount of DEM drape removed. Geometry stays byte-stable on a
    # second pass instead of rewriting the diagnostic as zero.
    if already_profiled:
        previous = (prior_summary.get("bridge") or {}).get("maximum_removed_dem_drape_m")
        if previous is not None:
            max_vertical_correction = float(previous)

    changed_partitions = set(owners[eid] for eid in bridge_profiles)
    for path in changed_partitions:
        payload = json.loads(path.read_text(encoding="utf-8"))
        for edge_id in list(payload):
            if edge_id in bridge_profiles:
                payload[edge_id] = edges[edge_id]
        path.write_text(json.dumps(payload, separators=(",", ":"), sort_keys=True), encoding="utf-8")

    touched_tiles = set()
    bridge_surface_records = 0
    for tile_entry in manifest.get("tiles", []):
        path = roads_root / str(tile_entry["file"])
        payload = json.loads(path.read_text(encoding="utf-8"))
        changed = False
        for segment in payload.get("segments", []):
            if not isinstance(segment, list) or len(segment) < 18:
                continue
            edge_id = str(segment[7])
            profile = bridge_profiles.get(edge_id)
            if profile is None:
                continue
            start_y, end_y = original_endpoints[edge_id]
            start_station, end_station = float(segment[16]), float(segment[17])
            polygon, uv = segment[11], segment[12]
            if len(polygon) != len(uv):
                raise ValueError(f"Bridge polygon/UV mismatch on {edge_id}")
            for point, texcoord in zip(polygon, uv):
                point[1] = round(_profile_y(start_y, end_y, start_station, end_station, float(texcoord[0])), 6)
            segment_index = int(segment[8])
            if 0 <= segment_index < len(profile) - 1:
                segment[9] = profile[segment_index][1]
                segment[10] = profile[segment_index + 1][1]
            bridge_surface_records += 1
            changed = True
        if changed:
            path.write_text(json.dumps(payload, separators=(",", ":")), encoding="utf-8")
            touched_tiles.add((int(tile_entry["x"]), int(tile_entry["z"])))

    summary = {
        "format": 1,
        "bridge": {
            "edges": len(bridge_profiles),
            "length_m": round(bridge_length, 3),
            "surface_records": bridge_surface_records,
            "tiles": len(touched_tiles),
            "maximum_removed_dem_drape_m": round(max_vertical_correction, 3),
            "profile": "linear deck between DEM-registered abutments",
            "collision": "runtime bridge deck mesh",
            "by_highway_type": dict(sorted(by_class.items())),
        },
        "tunnel": {
            "edges": tunnel_edges,
            "length_m": round(tunnel_length, 3),
            "status": "source-tagged; terrain corridor/portal pass required before vertical remapping",
        },
    }
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True), encoding="utf-8")
    manifest["structures"] = summary
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True), encoding="utf-8")
    return summary


def main() -> int:
    args = parse_args()
    summary = compile_structures(args.roads_root)
    print("YARDMAN_ROAD_STRUCTURES_PASS", json.dumps(summary, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
