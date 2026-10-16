#!/usr/bin/env python3
"""Build terrain-independent bridge decks and classified tunnel corridors.

Bridge abutments and tunnel portals stay registered to the DEM. Bridge decks
and explicit negative-layer tunnel axes are rebuilt as continuous profiles
between those endpoints instead of following terrain inside the structure.
Layer-zero tunnel tags are intentionally left terrain-conformed because they can
represent building passages or covered roads and need source classification
before terrain is cut.
"""
from __future__ import annotations

import argparse
import json
import math
import shutil
from pathlib import Path

BRIDGE_PROFILE_SOURCE = "DEM abutments + terrain-independent bridge deck"
TUNNEL_PROFILE_SOURCE = "DEM portals + terrain-independent negative-layer tunnel axis"


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


def _layer(edge: dict) -> int:
    try:
        return int(str(edge.get("layer", "0")))
    except ValueError:
        return 0


def _horizontal_stations(path):
    stations = [0.0]
    for a, b in zip(path, path[1:]):
        stations.append(stations[-1] + math.hypot(float(b[0]) - float(a[0]), float(b[2]) - float(a[2])))
    return stations


def _linear_profile(edge: dict):
    path = edge.get("path") or []
    if len(path) < 2:
        raise ValueError(f"Structure edge {edge.get('id')} has no usable path")
    stations = _horizontal_stations(path)
    total = stations[-1]
    if total <= 1e-6:
        raise ValueError(f"Structure edge {edge.get('id')} has zero horizontal length")
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


def _clip_axis_to_tile(a, b, tx: int, tz: int, tile_size: float):
    """Keep one shell's centerline inside its owning tile, including seam Y.

    A rendered ribbon fragment can occur in both neighboring tiles. Retaining
    the full source axis in both duplicates walls/ceiling across the seam.
    Interpolate XYZ on the same global segment so both clipped pieces agree.
    """
    t0, t1 = 0.0, 1.0
    for coordinate, minimum in ((0, tx * tile_size), (2, tz * tile_size)):
        maximum = minimum + tile_size
        start, delta = float(a[coordinate]), float(b[coordinate]) - float(a[coordinate])
        if abs(delta) < 1e-12:
            if start < minimum - 1e-9 or start >= maximum - 1e-9:
                return None
            continue
        first, last = (minimum - start) / delta, (maximum - start) / delta
        if first > last:
            first, last = last, first
        t0, t1 = max(t0, first), min(t1, last)
        if t1 - t0 <= 1e-9:
            return None
    return tuple([
        round(float(a[index]) + (float(b[index]) - float(a[index])) * t, 6)
        for index in range(3)
    ] for t in (t0, t1))


def compile_structures(roads_root: Path) -> dict:
    manifest_path = roads_root / "manifest.json"
    if not manifest_path.is_file():
        raise ValueError(f"Missing roads manifest: {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    tile_size = float(manifest["tile_size"])
    if not math.isfinite(tile_size) or tile_size <= 0:
        raise ValueError("Invalid structure tile size")
    edges, owners = _load_edges(roads_root)

    prior_summary = {}
    summary_path = roads_root / "structures.json"
    if summary_path.is_file():
        try:
            prior_summary = json.loads(summary_path.read_text(encoding="utf-8"))
        except (ValueError, OSError):
            prior_summary = {}

    already_profiled = bool(edges) and all(
        (not edge.get("bridge") or edge.get("elevation_source") == BRIDGE_PROFILE_SOURCE)
        and (not edge.get("tunnel") or _layer(edge) >= 0 or edge.get("elevation_source") == TUNNEL_PROFILE_SOURCE)
        for edge in edges.values()
    )

    profiles = {}
    original_endpoints = {}
    kinds = {}
    bridge_length = tunnel_length = 0.0
    bridge_max_correction = tunnel_max_correction = 0.0
    bridge_by_class = {}
    tunnel_by_class = {}
    tunnel_total_edges = 0
    tunnel_deferred = 0

    for edge_id, edge in edges.items():
        if edge.get("tunnel"):
            tunnel_total_edges += 1
            if _layer(edge) >= 0:
                tunnel_deferred += 1
                continue
            path = edge.get("path") or []
            if len(path) < 2:
                continue
            original_endpoints[edge_id] = (float(path[0][1]), float(path[-1][1]))
            profile, correction = _linear_profile(edge)
            profiles[edge_id] = profile
            kinds[edge_id] = "tunnel"
            edge["path"] = profile
            edge["elevation_source"] = TUNNEL_PROFILE_SOURCE
            tunnel_length += float(edge.get("length_m", 0.0) or 0.0)
            tunnel_max_correction = max(tunnel_max_correction, correction)
            klass = str(edge.get("class", "unknown"))
            tunnel_by_class[klass] = tunnel_by_class.get(klass, 0) + 1
            continue
        if not edge.get("bridge"):
            continue
        path = edge.get("path") or []
        if len(path) < 2:
            continue
        original_endpoints[edge_id] = (float(path[0][1]), float(path[-1][1]))
        profile, correction = _linear_profile(edge)
        profiles[edge_id] = profile
        kinds[edge_id] = "bridge"
        edge["path"] = profile
        edge["elevation_source"] = BRIDGE_PROFILE_SOURCE
        bridge_length += float(edge.get("length_m", 0.0) or 0.0)
        bridge_max_correction = max(bridge_max_correction, correction)
        klass = str(edge.get("class", "unknown"))
        bridge_by_class[klass] = bridge_by_class.get(klass, 0) + 1

    if already_profiled:
        old_bridge = prior_summary.get("bridge") or {}
        old_tunnel = prior_summary.get("tunnel") or {}
        if old_bridge.get("maximum_removed_dem_drape_m") is not None:
            bridge_max_correction = float(old_bridge["maximum_removed_dem_drape_m"])
        if old_tunnel.get("maximum_removed_dem_drape_m") is not None:
            tunnel_max_correction = float(old_tunnel["maximum_removed_dem_drape_m"])

    changed_partitions = set(owners[eid] for eid in profiles)
    for path in changed_partitions:
        payload = json.loads(path.read_text(encoding="utf-8"))
        for edge_id in list(payload):
            if edge_id in profiles:
                payload[edge_id] = edges[edge_id]
        path.write_text(json.dumps(payload, separators=(",", ":"), sort_keys=True), encoding="utf-8")

    structure_dir = roads_root / "structures"
    if structure_dir.exists():
        shutil.rmtree(structure_dir)
    structure_dir.mkdir(parents=True)
    bridge_tiles = set()
    tunnel_tiles = set()
    bridge_surface_records = tunnel_surface_records = 0
    tunnel_pieces_by_tile = {}

    for tile_entry in manifest.get("tiles", []):
        tx, tz = int(tile_entry["x"]), int(tile_entry["z"])
        path = roads_root / str(tile_entry["file"])
        payload = json.loads(path.read_text(encoding="utf-8"))
        changed = False
        compact_tunnels = {}
        for segment in payload.get("segments", []):
            if not isinstance(segment, list) or len(segment) < 18:
                continue
            edge_id = str(segment[7])
            profile = profiles.get(edge_id)
            if profile is None:
                continue
            start_y, end_y = original_endpoints[edge_id]
            start_station, end_station = float(segment[16]), float(segment[17])
            polygon, uv = segment[11], segment[12]
            if len(polygon) != len(uv):
                raise ValueError(f"Structure polygon/UV mismatch on {edge_id}")
            for point, texcoord in zip(polygon, uv):
                point[1] = round(_profile_y(start_y, end_y, start_station, end_station, float(texcoord[0])), 6)
            segment_index = int(segment[8])
            if 0 <= segment_index < len(profile) - 1:
                segment[9] = profile[segment_index][1]
                segment[10] = profile[segment_index + 1][1]
            if kinds[edge_id] == "bridge":
                bridge_surface_records += 1
                bridge_tiles.add((tx, tz))
            else:
                tunnel_surface_records += 1
                tunnel_tiles.add((tx, tz))
                if 0 <= segment_index < len(profile) - 1:
                    a, b = profile[segment_index], profile[segment_index + 1]
                    clipped = _clip_axis_to_tile(a, b, tx, tz, tile_size)
                    if clipped is not None:
                        compact_tunnels[(edge_id, segment_index)] = {
                            "edge_id": edge_id,
                            "segment_index": segment_index,
                            "a": clipped[0], "b": clipped[1],
                            "width_m": float(segment[4]),
                            "layer": _layer(edges[edge_id]),
                        }
            changed = True
        if changed:
            path.write_text(json.dumps(payload, separators=(",", ":")), encoding="utf-8")
        if compact_tunnels:
            filename = f"tile_{tx}_{tz}.json"
            values = [compact_tunnels[key] for key in sorted(compact_tunnels)]
            (structure_dir / filename).write_text(
                json.dumps({"tile": [tx, tz], "tunnels": values}, separators=(",", ":")), encoding="utf-8")
            tunnel_pieces_by_tile[(tx, tz)] = {"file": "structures/" + filename, "segments": len(values)}

    structure_tiles = [
        {"x": tx, "z": tz, **tunnel_pieces_by_tile[(tx, tz)]}
        for tx, tz in sorted(tunnel_pieces_by_tile)
    ]
    summary = {
        "format": 2,
        "bridge": {
            "edges": sum(1 for kind in kinds.values() if kind == "bridge"),
            "length_m": round(bridge_length, 3),
            "surface_records": bridge_surface_records,
            "tiles": len(bridge_tiles),
            "maximum_removed_dem_drape_m": round(bridge_max_correction, 3),
            "profile": "linear deck between DEM-registered abutments",
            "collision": "runtime bridge deck mesh",
            "by_highway_type": dict(sorted(bridge_by_class.items())),
        },
        "tunnel": {
            "source_edges": tunnel_total_edges,
            "profiled_edges": sum(1 for kind in kinds.values() if kind == "tunnel"),
            "deferred_nonnegative_layer_edges": tunnel_deferred,
            "length_m": round(tunnel_length, 3),
            "surface_records": tunnel_surface_records,
            "tiles": len(tunnel_tiles),
            "maximum_removed_dem_drape_m": round(tunnel_max_correction, 3),
            "profile": "linear bore axis between DEM-registered portals",
            "collision": "runtime tunnel deck and CSG terrain bore",
            "by_highway_type": dict(sorted(tunnel_by_class.items())),
        },
        "tunnel_tiles": structure_tiles,
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
