#!/usr/bin/env python3
"""Validate real compiled bridge/tunnel payloads independently of rendering."""
from __future__ import annotations

import argparse
import json
import math
from collections import defaultdict
from pathlib import Path


def validate_payloads(manifest: dict, read_json) -> dict:
    structures = manifest.get("structures")
    if not isinstance(structures, dict) or structures.get("format") != 2:
        raise ValueError("National road manifest has no compiled structure registry")
    if read_json("structures.json") != structures:
        raise ValueError("Structure summary differs from the national road manifest")
    tile_size = float(manifest["tile_size"])
    if not math.isfinite(tile_size) or tile_size <= 0:
        raise ValueError("Invalid road tile size")
    pieces = 0
    spans = defaultdict(list)
    for tile in structures.get("tunnel_tiles", []):
        payload = read_json(str(tile["file"]))
        tx, tz = int(tile["x"]), int(tile["z"])
        if payload.get("tile") != [tx, tz]:
            raise ValueError("Tunnel corridor has the wrong tile address")
        tunnels = payload.get("tunnels", [])
        if len(tunnels) != int(tile["segments"]):
            raise ValueError("Tunnel corridor segment count differs from its registry")
        seen = set()
        for tunnel in tunnels:
            identity = (str(tunnel["edge_id"]), int(tunnel["segment_index"]))
            if identity in seen:
                raise ValueError("Duplicate tunnel axis in one tile")
            seen.add(identity)
            if int(tunnel["layer"]) >= 0 or float(tunnel["width_m"]) <= 0:
                raise ValueError("Unclassified tunnel corridor was compiled")
            a, b = tunnel["a"], tunnel["b"]
            if len(a) != 3 or len(b) != 3 or not all(math.isfinite(float(v)) for v in (*a, *b)):
                raise ValueError("Invalid tunnel axis coordinates")
            for point in (a, b):
                if not (tx * tile_size - 2e-6 <= float(point[0]) <= (tx + 1) * tile_size + 2e-6
                        and tz * tile_size - 2e-6 <= float(point[2]) <= (tz + 1) * tile_size + 2e-6):
                    raise ValueError("Tunnel shell axis escapes its owning tile")
            if math.hypot(float(a[0]) - float(b[0]), float(a[2]) - float(b[2])) < 1e-6:
                raise ValueError("Empty tunnel shell axis")
            span = (tuple(a), tuple(b))
            if span in spans[identity]:
                raise ValueError("Full tunnel span was duplicated across tile boundaries")
            spans[identity].append(span)
            pieces += 1

    registry = manifest.get("tunnel_portals")
    if not isinstance(registry, dict) or registry.get("format") != 1:
        raise ValueError("National road manifest has no compiled tunnel portal registry")
    portal_manifest = read_json(str(registry["manifest_file"]))
    if portal_manifest.get("anomalies"):
        raise ValueError("Tunnel topology contains unclassified portal anomalies")
    if (int(portal_manifest["portals"]) != int(registry["portals"])
            or int(portal_manifest["profiled_tunnel_source_ways"]) != int(registry["profiled_tunnel_source_ways"])
            or float(portal_manifest["tile_size"]) != tile_size):
        raise ValueError("Portal summary differs from the national road manifest")
    source_tiles = [{**tile, "file": "tunnel_portals/" + tile["file"]}
                    for tile in portal_manifest.get("tiles", [])]
    if registry.get("tiles") != source_tiles:
        raise ValueError("Portal tile registry differs from its compiled manifest")
    count = 0
    identities = set()
    for tile in registry["tiles"]:
        payload = read_json(str(tile["file"]))
        tx, tz = int(tile["x"]), int(tile["z"])
        if payload.get("tile") != [tx, tz] or len(payload.get("portals", [])) != int(tile["portals"]):
            raise ValueError("Portal tile address/count differs from its registry")
        for portal in payload["portals"]:
            identity = (str(portal["source_way"]), str(portal["node_id"]))
            if identity in identities:
                raise ValueError("Duplicate tunnel portal")
            identities.add(identity)
            p, q = portal["position"], portal["toward"]
            if (len(p) != 3 or len(q) != 3 or not all(math.isfinite(float(v)) for v in (*p, *q))
                    or math.hypot(float(p[0]) - float(q[0]), float(p[2]) - float(q[2])) <= 1e-6):
                raise ValueError("Invalid tunnel portal direction")
            if [math.floor(float(p[0]) / tile_size), math.floor(float(p[2]) / tile_size)] != [tx, tz]:
                raise ValueError("Tunnel portal belongs to a different tile")
            if int(portal["layer"]) >= 0 or float(portal["width_m"]) <= 0:
                raise ValueError("Unclassified tunnel portal was compiled")
            count += 1
    if count != int(registry["portals"]):
        raise ValueError("Tunnel portal payload count does not match the national registry")
    return {"bridge_edges": int(structures["bridge"]["edges"]),
            "profiled_tunnel_edges": int(structures["tunnel"]["profiled_edges"]),
            "tunnel_corridor_tiles": len(structures["tunnel_tiles"]),
            "tunnel_shell_segments": pieces,
            "tunnel_source_ways": int(registry["profiled_tunnel_source_ways"]),
            "tunnel_portals": count, "portal_tiles": len(registry["tiles"])}


def validate_root(root: Path) -> dict:
    root = root.resolve()
    manifest = json.loads((root / "manifest.json").read_text())

    def read_json(relative: str):
        path = root / relative
        if Path(relative).is_absolute() or ".." in Path(relative).parts:
            raise ValueError("Invalid road structure resource path")
        if not path.is_file():
            raise ValueError("Missing compiled road structure resource: " + relative)
        return json.loads(path.read_text())

    return validate_payloads(manifest, read_json)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("roads_root", type=Path)
    args = parser.parse_args()
    print("YARDMAN_ROAD_STRUCTURE_DATA_PASS", json.dumps(validate_root(args.roads_root), sort_keys=True))
