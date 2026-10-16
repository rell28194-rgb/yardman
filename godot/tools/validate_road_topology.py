#!/usr/bin/env python3
"""Validate the packaged Yardman Jamaica road graph.

This checks topology independently of rendered road meshes. Legitimate dead ends
and isolated service roads are reported rather than rewritten. The validator
fails only on structural corruption and, when requested, if parish anchors do
not share a connected drivable component.
"""
from __future__ import annotations

import argparse
import json
import math
from collections import defaultdict, deque
from pathlib import Path

CORE_CLASSES = {
    "motorway", "motorway_link", "trunk", "trunk_link",
    "primary", "primary_link", "secondary", "secondary_link",
    "tertiary", "tertiary_link",
}


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("roads_root", type=Path)
    p.add_argument("--output", type=Path)
    p.add_argument("--near-miss-metres", type=float, default=2.5)
    p.add_argument("--require-anchor-component", action="store_true")
    return p.parse_args()


def _load_partitions(root: Path, kind: str) -> dict:
    result = {}
    paths = sorted((root / "graph").glob(f"{kind}_*.json"))
    if not paths:
        raise ValueError(f"No {kind} graph partitions found under {root / 'graph'}")
    for path in paths:
        payload = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(payload, dict):
            raise ValueError(f"Invalid graph partition {path}")
        duplicate = set(result).intersection(payload)
        if duplicate:
            raise ValueError(f"Duplicate {kind} identifiers: {sorted(duplicate)[:3]}")
        result.update(payload)
    return result


def _edge_nodes(edge: dict) -> tuple[str, str]:
    return str(edge.get("from", "")), str(edge.get("to", ""))


def _build_adjacency(nodes: dict, edges: dict, allowed_classes=None):
    weak = defaultdict(set)
    directed = defaultdict(set)
    accepted = set()
    for edge_id, edge in edges.items():
        if allowed_classes is not None and str(edge.get("class")) not in allowed_classes:
            continue
        a, b = _edge_nodes(edge)
        if not a or not b or a not in nodes or b not in nodes:
            raise ValueError(f"Graph edge {edge_id} references a missing node")
        accepted.add(edge_id)
        weak[a].add(b); weak[b].add(a)
        direction = int(edge.get("direction", 0))
        if direction >= 0:
            directed[a].add(b)
        if direction <= 0:
            directed[b].add(a)
    return weak, directed, accepted


def _components(nodes: dict, edges: dict, weak: dict, accepted: set[str]):
    active = set()
    for edge_id in accepted:
        a, b = _edge_nodes(edges[edge_id])
        active.add(a); active.add(b)
    component_of = {}
    components = []
    for start in sorted(active):
        if start in component_of:
            continue
        cid = len(components)
        q = [start]
        component_of[start] = cid
        members = []
        while q:
            current = q.pop()
            members.append(current)
            for nxt in weak.get(current, ()):
                if nxt not in component_of:
                    component_of[nxt] = cid
                    q.append(nxt)
        components.append({"id": cid, "nodes": len(members), "edges": 0,
                           "length_m": 0.0, "sample_node": members[0]})
    for edge_id in accepted:
        edge = edges[edge_id]
        a, _ = _edge_nodes(edge)
        cid = component_of[a]
        components[cid]["edges"] += 1
        components[cid]["length_m"] += float(edge.get("length_m", 0.0) or 0.0)
    for item in components:
        item["length_m"] = round(item["length_m"], 3)
    components.sort(key=lambda c: (c["edges"], c["nodes"], c["length_m"]), reverse=True)
    # Sorting changes public report order but component ids remain stable for lookups.
    return component_of, components


def _anchor_edge(manifest: dict, parish: str, edges: dict) -> dict:
    entry = (manifest.get("parish_anchors") or {}).get(parish) or {}
    edge_id = str(entry.get("road_edge_id", ""))
    if edge_id not in edges:
        raise ValueError(f"Parish anchor {parish} references missing edge {edge_id!r}")
    return edges[edge_id]


def _anchor_component_report(manifest: dict, edges: dict, component_of: dict):
    by_component = defaultdict(list)
    anchor_components = {}
    for parish in sorted((manifest.get("parish_anchors") or {})):
        edge = _anchor_edge(manifest, parish, edges)
        a, b = _edge_nodes(edge)
        ca, cb = component_of.get(a), component_of.get(b)
        if ca is None or cb is None or ca != cb:
            raise ValueError(f"Anchor edge for {parish} is not internally connected")
        anchor_components[parish] = ca
        by_component[ca].append(parish)
    return anchor_components, {str(k): v for k, v in sorted(by_component.items())}


def _anchor_departure_nodes(edge: dict) -> set[str]:
    a, b = _edge_nodes(edge)
    direction = int(edge.get("direction", 0))
    if direction > 0:
        return {b}
    if direction < 0:
        return {a}
    return {a, b}


def _anchor_arrival_nodes(edge: dict) -> set[str]:
    a, b = _edge_nodes(edge)
    direction = int(edge.get("direction", 0))
    if direction > 0:
        return {a}
    if direction < 0:
        return {b}
    return {a, b}


def _reachable(starts: set[str], directed: dict) -> set[str]:
    seen = set(starts)
    q = deque(starts)
    while q:
        current = q.popleft()
        for nxt in directed.get(current, ()):
            if nxt not in seen:
                seen.add(nxt)
                q.append(nxt)
    return seen


def _directed_anchor_report(manifest: dict, edges: dict, directed: dict):
    anchors = manifest.get("parish_anchors") or {}
    if "Kingston" not in anchors:
        return {"origin": None, "reachable": [], "unreachable": sorted(anchors)}
    origin_edge = _anchor_edge(manifest, "Kingston", edges)
    seen = _reachable(_anchor_departure_nodes(origin_edge), directed)
    reachable, unreachable = [], []
    for parish in sorted(anchors):
        edge = _anchor_edge(manifest, parish, edges)
        target_nodes = _anchor_arrival_nodes(edge)
        (reachable if seen.intersection(target_nodes) else unreachable).append(parish)
    return {"origin": "Kingston", "reachable": reachable, "unreachable": unreachable,
            "visited_nodes": len(seen)}


def _incident_profile(node_id: str, nodes: dict, edges: dict):
    edge_ids = [str(x) for x in nodes[node_id].get("edges", []) if str(x) in edges]
    if len(edge_ids) != 1:
        return None
    edge = edges[edge_ids[0]]
    try:
        layer = int(str(edge.get("layer", "0")))
    except ValueError:
        layer = 0
    return {
        "edge_id": edge_ids[0], "source_way": str(edge.get("source_way", "")),
        "layer": layer, "bridge": bool(edge.get("bridge")), "tunnel": bool(edge.get("tunnel")),
        "class": str(edge.get("class", "")),
    }


def _near_misses(nodes: dict, edges: dict, weak: dict, threshold: float):
    if threshold <= 0 or not math.isfinite(threshold):
        raise ValueError("near-miss threshold must be finite and positive")
    endpoints = []
    for node_id, node in nodes.items():
        if len(weak.get(node_id, ())) != 1:
            continue
        pos = node.get("position") or []
        if len(pos) < 3:
            continue
        profile = _incident_profile(node_id, nodes, edges)
        if profile is None:
            continue
        endpoints.append((node_id, float(pos[0]), float(pos[2]), profile))
    cell = threshold
    buckets = defaultdict(list)
    suspects = []
    for item in endpoints:
        node_id, x, z, profile = item
        bx, bz = math.floor(x / cell), math.floor(z / cell)
        for dz in (-1, 0, 1):
            for dx in (-1, 0, 1):
                for other in buckets.get((bx + dx, bz + dz), ()):
                    oid, ox, oz, op = other
                    if oid in weak.get(node_id, ()):
                        continue
                    distance = math.hypot(x - ox, z - oz)
                    if distance > threshold or distance < 1e-6:
                        continue
                    # Grade-separated endpoints are not candidates for an at-grade join.
                    if profile["layer"] != op["layer"]:
                        continue
                    if profile["bridge"] != op["bridge"] or profile["tunnel"] != op["tunnel"]:
                        continue
                    suspects.append({
                        "a": oid, "b": node_id, "distance_m": round(distance, 3),
                        "a_edge": op["edge_id"], "b_edge": profile["edge_id"],
                        "a_class": op["class"], "b_class": profile["class"],
                        "same_source_way": op["source_way"] == profile["source_way"],
                    })
        buckets[(bx, bz)].append(item)
    suspects.sort(key=lambda x: (x["distance_m"], x["a"], x["b"]))
    return len(endpoints), suspects


def _nearest_core_edge(anchor: dict, edges: dict):
    ax, az = float(anchor["x"]), float(anchor["z"])
    best = (float("inf"), None)
    for edge_id, edge in edges.items():
        if str(edge.get("class")) not in CORE_CLASSES:
            continue
        path = edge.get("path") or []
        for p, q in zip(path, path[1:]):
            px, pz, qx, qz = float(p[0]), float(p[2]), float(q[0]), float(q[2])
            vx, vz = qx - px, qz - pz
            denom = vx * vx + vz * vz
            t = 0.0 if denom <= 1e-12 else max(0.0, min(1.0, ((ax - px) * vx + (az - pz) * vz) / denom))
            dx, dz = ax - (px + t * vx), az - (pz + t * vz)
            d = math.hypot(dx, dz)
            if d < best[0]:
                best = (d, edge_id)
    return best


def validate(roads_root: Path, near_miss_metres: float = 2.5,
             require_anchor_component: bool = False) -> dict:
    manifest_path = roads_root / "manifest.json"
    if not manifest_path.is_file():
        raise ValueError(f"Missing road manifest: {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    nodes = _load_partitions(roads_root, "nodes")
    edges = _load_partitions(roads_root, "edges")
    expected = manifest.get("graph") or {}
    if int(expected.get("nodes", -1)) != len(nodes) or int(expected.get("edges", -1)) != len(edges):
        raise ValueError("Graph partition counts do not match manifest")

    weak, directed, accepted = _build_adjacency(nodes, edges)
    component_of, components = _components(nodes, edges, weak, accepted)
    anchor_components, anchor_groups = _anchor_component_report(manifest, edges, component_of)
    if require_anchor_component and len(set(anchor_components.values())) != 1:
        raise ValueError("Parish anchors span disconnected road components: " + json.dumps(anchor_groups, sort_keys=True))

    core_weak, _, core_edges = _build_adjacency(nodes, edges, CORE_CLASSES)
    core_component_of, core_components = _components(nodes, edges, core_weak, core_edges)
    core_anchor = {}
    for parish, anchor in sorted((manifest.get("parish_anchors") or {}).items()):
        distance, edge_id = _nearest_core_edge(anchor, edges)
        edge = edges[edge_id] if edge_id else None
        component = core_component_of.get(_edge_nodes(edge)[0]) if edge else None
        core_anchor[parish] = {"distance_m": round(distance, 1), "edge_id": edge_id, "component": component}

    endpoint_count, suspects = _near_misses(nodes, edges, weak, near_miss_metres)
    directed_report = _directed_anchor_report(manifest, edges, directed)
    total_length = sum(float(e.get("length_m", 0.0) or 0.0) for e in edges.values())
    largest = components[0] if components else {"nodes": 0, "edges": 0, "length_m": 0.0}
    large_components = [c for c in components if c["length_m"] >= 1000.0]

    report = {
        "format": 1,
        "graph": {"nodes": len(nodes), "edges": len(edges), "length_m": round(total_length, 3)},
        "components": {
            "count": len(components), "over_1km": len(large_components),
            "largest": largest,
            "largest_edge_ratio": round(largest["edges"] / max(1, len(edges)), 6),
            "largest_length_ratio": round(largest["length_m"] / max(1.0, total_length), 6),
            "top10": components[:10],
        },
        "parish_anchors": {
            "component_count": len(set(anchor_components.values())),
            "groups": anchor_groups,
            "directed_from_kingston": directed_report,
        },
        "core_backbone": {
            "classes": sorted(CORE_CLASSES), "edges": len(core_edges),
            "components": len(core_components), "top10": core_components[:10],
            "nearest_by_parish": core_anchor,
        },
        "dangling_endpoints": endpoint_count,
        "near_miss_threshold_m": near_miss_metres,
        "suspect_near_miss_count": len(suspects),
        "suspect_near_misses": suspects[:100],
    }
    return report


def main() -> int:
    args = parse_args()
    report = validate(args.roads_root, args.near_miss_metres, args.require_anchor_component)
    output = args.output or (args.roads_root / "topology_report.json")
    output.write_text(json.dumps(report, indent=2, sort_keys=True), encoding="utf-8")
    print("YARDMAN_ROAD_TOPOLOGY_PASS", json.dumps({
        "components": report["components"]["count"],
        "largest_edge_ratio": report["components"]["largest_edge_ratio"],
        "anchor_components": report["parish_anchors"]["component_count"],
        "directed_unreachable": report["parish_anchors"]["directed_from_kingston"]["unreachable"],
        "core_components": report["core_backbone"]["components"],
        "near_misses": report["suspect_near_miss_count"],
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
