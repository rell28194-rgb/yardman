#!/usr/bin/env python3
"""Compile source-backed road cut/fill evidence and DEM review candidates.

This stage deliberately does not reshape terrain. Explicit OSM cutting,
embankment and ford tags are preserved as source truth. Where those tags are
absent, local DEM cross-slope is used only to flag review candidates for cut,
fill or side-hill treatment; it is never promoted to a factual earthwork.
"""
from __future__ import annotations

import argparse
import json
import math
import shutil
from collections import Counter, defaultdict
from pathlib import Path

from build_hydrology import parse_bool_tag, parse_layer, split_segment_by_tile

DRIVABLE_HIGHWAYS = {
    "motorway", "motorway_link", "trunk", "trunk_link", "primary", "primary_link",
    "secondary", "secondary_link", "tertiary", "tertiary_link", "unclassified",
    "residential", "living_street", "service", "road", "track", "raceway",
}
ROAD_WIDTH_FALLBACK_M = {
    "motorway": 8.4, "motorway_link": 4.6,
    "trunk": 8.0, "trunk_link": 4.3,
    "primary": 7.2, "primary_link": 4.0,
    "secondary": 6.8, "secondary_link": 3.8,
    "tertiary": 6.4, "tertiary_link": 3.6,
    "unclassified": 5.8, "residential": 5.5,
    "living_street": 4.5, "service": 3.5,
    "road": 5.8, "track": 3.0, "raceway": 8.0,
}
FALSE_TAGS = {"", "no", "false", "0"}


def active_tag(raw) -> bool:
    return str(raw or "").strip().lower() not in FALSE_TAGS


def parse_width(raw, highway: str) -> tuple[float, str]:
    text = str(raw or "").strip().lower()
    number = ""
    for char in text:
        if char.isdigit() or char in ".-+":
            number += char
        elif number:
            break
    if number:
        try:
            value = float(number)
            if math.isfinite(value) and value > 0.0:
                return max(1.0, min(30.0, value)), "source"
        except ValueError:
            pass
    return ROAD_WIDTH_FALLBACK_M.get(highway, 5.8), "class_fallback"


def classify_earthwork(tags: dict, left_delta_m: float, right_delta_m: float) -> tuple[str, bool, str]:
    """Return classification, source-resolved flag, and reason."""
    if active_tag(tags.get("bridge")):
        return "bridge_deferred", True, "source road bridge tag"
    if active_tag(tags.get("tunnel")) or active_tag(tags.get("covered")):
        return "tunnel_or_covered_deferred", True, "source tunnel/covered road tag"
    if parse_bool_tag(tags.get("ford")):
        return "source_ford", True, "source ford tag"
    if active_tag(tags.get("cutting")):
        return "source_cutting", True, "source cutting tag"
    if active_tag(tags.get("embankment")):
        return "source_embankment", True, "source embankment tag"

    threshold = 2.0
    sidehill_threshold = 3.0
    if left_delta_m >= threshold and right_delta_m >= threshold:
        return "dem_cut_candidate", False, "both DEM shoulders materially above road center"
    if left_delta_m <= -threshold and right_delta_m <= -threshold:
        return "dem_fill_candidate", False, "both DEM shoulders materially below road center"
    if left_delta_m * right_delta_m < 0.0 and abs(left_delta_m - right_delta_m) >= sidehill_threshold:
        return "dem_sidehill_candidate", False, "opposing shoulder relief indicates side-hill bench review"
    return "none", False, "no source earthwork and insufficient DEM relief"


def compile_earthworks(osm_pbf: Path, terrain_root: Path, output_root: Path) -> dict:
    try:
        import osmium
        from pyproj import Transformer
    except ImportError as exc:  # pragma: no cover
        raise RuntimeError("build_road_earthworks requires osmium and pyproj") from exc

    from build_terrain import TerrainSampler

    terrain_manifest = json.loads((terrain_root / "manifest.json").read_text(encoding="utf-8"))
    tile_size = float(terrain_manifest["tile_size"])
    origin = terrain_manifest["origin"]
    e0, n0 = float(origin["easting"]), float(origin["northing"])
    project = Transformer.from_crs(4326, 3448, always_xy=True)
    sampler = TerrainSampler(terrain_root)
    records_by_tile: dict[tuple[int, int], list[dict]] = defaultdict(list)
    stats: Counter = Counter()

    class Handler(osmium.SimpleHandler):
        def way(self, way) -> None:
            highway = str(way.tags.get("highway", ""))
            if highway not in DRIVABLE_HIGHWAYS:
                return
            points = []
            for node in way.nodes:
                try:
                    if not node.location.valid():
                        continue
                    easting, northing = project.transform(node.location.lon, node.location.lat)
                except Exception:
                    continue
                points.append((float(easting) - e0, n0 - float(northing), int(node.ref)))
            if len(points) < 2:
                return
            tags = dict(way.tags)
            width_m, width_source = parse_width(tags.get("width"), highway)
            source_way = f"w{int(way.id)}"
            for source_segment_index, (source_a, source_b) in enumerate(zip(points, points[1:])):
                a2, b2 = source_a[:2], source_b[:2]
                for (tx, tz), a, b in split_segment_by_tile(a2, b2, tile_size):
                    dx, dz = b[0] - a[0], b[1] - a[1]
                    length = math.hypot(dx, dz)
                    if length <= 0.10:
                        continue
                    mid_x, mid_z = (a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5
                    center_y = float(sampler(mid_x, mid_z))
                    right_x, right_z = -dz / length, dx / length
                    shoulder_offset = width_m * 0.5 + 6.0
                    left_y = float(sampler(mid_x + right_x * shoulder_offset, mid_z + right_z * shoulder_offset))
                    right_y = float(sampler(mid_x - right_x * shoulder_offset, mid_z - right_z * shoulder_offset))
                    if not all(math.isfinite(value) for value in (center_y, left_y, right_y)):
                        stats["nonfinite_profiles"] += 1
                        continue
                    left_delta, right_delta = left_y - center_y, right_y - center_y
                    classification, source_resolved, reason = classify_earthwork(tags, left_delta, right_delta)
                    if classification == "none":
                        continue
                    record = {
                        "source_way": source_way,
                        "source_segment_index": source_segment_index,
                        "source_node_a": int(source_a[2]),
                        "source_node_b": int(source_b[2]),
                        "highway": highway,
                        "name": str(tags.get("name", "")),
                        "ref": str(tags.get("ref", "")),
                        "a": [round(a[0], 6), round(float(sampler(a[0], a[1])), 6), round(a[1], 6)],
                        "b": [round(b[0], 6), round(float(sampler(b[0], b[1])), 6), round(b[1], 6)],
                        "width_m": round(width_m, 3),
                        "width_source": width_source,
                        "shoulder_offset_m": round(shoulder_offset, 3),
                        "cross_section": {
                            "center_y": round(center_y, 6),
                            "left_y": round(left_y, 6),
                            "right_y": round(right_y, 6),
                            "left_delta_m": round(left_delta, 3),
                            "right_delta_m": round(right_delta, 3),
                        },
                        "classification": classification,
                        "resolved_by_source": source_resolved,
                        "reason": reason,
                        "source_tags": {
                            "cutting": str(tags.get("cutting", "")),
                            "embankment": str(tags.get("embankment", "")),
                            "ford": str(tags.get("ford", "")),
                            "bridge": str(tags.get("bridge", "")),
                            "tunnel": str(tags.get("tunnel", "")),
                            "covered": str(tags.get("covered", "")),
                            "layer": parse_layer(tags.get("layer")),
                            "location": str(tags.get("location", "")),
                            "surface": str(tags.get("surface", "")),
                        },
                    }
                    records_by_tile[(tx, tz)].append(record)
                    stats["records"] += 1
                    stats[f"classification_{classification}"] += 1
                    stats["source_resolved" if source_resolved else "dem_review_candidates"] += 1

    Handler().apply_file(str(osm_pbf), locations=True)

    staging = output_root.with_name(output_root.name + ".staging")
    if staging.exists():
        shutil.rmtree(staging)
    (staging / "tiles").mkdir(parents=True)
    tiles = []
    for (tx, tz), records in sorted(records_by_tile.items()):
        records.sort(key=lambda item: (item["source_way"], item["source_segment_index"], item["a"][0], item["a"][2]))
        relative = f"tiles/tile_{tx}_{tz}.json"
        (staging / relative).write_text(
            json.dumps({"tile": [tx, tz], "earthworks": records}, separators=(",", ":")),
            encoding="utf-8",
        )
        tiles.append({"x": tx, "z": tz, "file": relative, "records": len(records)})

    manifest = {
        "format": 1,
        "source": "OpenStreetMap road earthwork tags + DEM cross-slope diagnostics",
        "policy": "explicit tags are source truth; DEM-only classifications are review candidates and must not reshape terrain automatically",
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
    parser.add_argument("terrain_root", type=Path)
    parser.add_argument("output_root", type=Path)
    args = parser.parse_args()
    manifest = compile_earthworks(args.osm_pbf, args.terrain_root, args.output_root)
    print("YARDMAN_ROAD_EARTHWORK_TRUTH_PASS", json.dumps(manifest["stats"], sort_keys=True),
          "tiles=", len(manifest["tiles"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
