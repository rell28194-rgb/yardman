#!/usr/bin/env python3
"""Compile physical terrain-replacement corridors for source-tagged road earthworks.

Only explicit OSM `cutting` and `embankment` records from the road-earthwork
truth pack are eligible. DEM-only candidates never reach this stage. Even a
source-tagged record is deferred when the available DEM cross-section does not
support the tagged physical relationship strongly enough to reconstruct it.

The output does not alter road centerlines. It supplies a narrow terrain mask
plus left/right transition surfaces between the existing road edge and sampled
terrain outside the earthwork corridor. That lets runtime cut the coarse 64 m
terrain skin and insert a high-resolution side slope instead of pasting a road
ribbon across an intact hillside.
"""
from __future__ import annotations

import argparse
import json
import math
import shutil
from collections import Counter, defaultdict
from pathlib import Path

SOURCE_KINDS = {"source_cutting", "source_embankment"}
MIN_SUPPORT_RELIEF_M = 0.50
OUTER_OVERLAP_M = 1.0
ROAD_EDGE_SHOULDER_M = 0.75


def source_geometry_supported(kind: str, left_delta_m: float, right_delta_m: float,
                              minimum_relief_m: float = MIN_SUPPORT_RELIEF_M) -> tuple[bool, str]:
    if kind not in SOURCE_KINDS:
        return False, "not a source cutting/embankment"
    if not all(math.isfinite(float(value)) for value in (left_delta_m, right_delta_m, minimum_relief_m)):
        return False, "non-finite cross-section"
    if minimum_relief_m <= 0.0:
        raise ValueError("minimum relief must be positive")
    if kind == "source_cutting":
        if max(left_delta_m, right_delta_m) >= minimum_relief_m:
            return True, "source cutting supported by raised DEM shoulder"
        return False, "source cutting tag present but DEM lacks resolvable raised shoulder"
    if min(left_delta_m, right_delta_m) <= -minimum_relief_m:
        return True, "source embankment supported by lowered DEM shoulder"
    return False, "source embankment tag present but DEM lacks resolvable lowered shoulder"


def _sample_outer(sampler, x: float, z: float, right_x: float, right_z: float, offset: float):
    left = float(sampler(x + right_x * offset, z + right_z * offset))
    right = float(sampler(x - right_x * offset, z - right_z * offset))
    if not math.isfinite(left) or not math.isfinite(right):
        raise ValueError("non-finite DEM earthwork shoulder")
    return left, right


def compile_geometry(terrain_root: Path, earthworks_root: Path, output_root: Path) -> dict:
    from build_terrain import TerrainSampler

    earthwork_manifest = json.loads((earthworks_root / "manifest.json").read_text(encoding="utf-8"))
    sampler = TerrainSampler(terrain_root)
    records_by_tile: dict[tuple[int, int], list[dict]] = defaultdict(list)
    stats: Counter = Counter()

    for tile in earthwork_manifest.get("tiles", []):
        tx, tz = int(tile["x"]), int(tile["z"])
        payload = json.loads((earthworks_root / str(tile["file"])).read_text(encoding="utf-8"))
        for record in payload.get("earthworks", []):
            kind = str(record.get("classification", ""))
            if kind not in SOURCE_KINDS:
                continue
            stats["source_records_seen"] += 1
            cross = record.get("cross_section", {})
            left_delta = float(cross.get("left_delta_m", 0.0))
            right_delta = float(cross.get("right_delta_m", 0.0))
            supported, reason = source_geometry_supported(kind, left_delta, right_delta)
            if not supported:
                stats["source_records_deferred_dem_resolution"] += 1
                stats[f"deferred_{kind}"] += 1
                continue

            a = record.get("a", [])
            b = record.get("b", [])
            if not isinstance(a, list) or not isinstance(b, list) or len(a) < 3 or len(b) < 3:
                stats["invalid_records"] += 1
                continue
            ax, ay, az = float(a[0]), float(a[1]), float(a[2])
            bx, by, bz = float(b[0]), float(b[1]), float(b[2])
            dx, dz = bx - ax, bz - az
            length = math.hypot(dx, dz)
            if length <= 0.25:
                stats["degenerate_records"] += 1
                continue
            right_x, right_z = -dz / length, dx / length
            road_width = max(1.0, float(record.get("width_m", 5.8)))
            road_half = road_width * 0.5 + ROAD_EDGE_SHOULDER_M
            outer = max(road_half + 2.0, float(record.get("shoulder_offset_m", road_half + 5.25)))

            try:
                a_left, a_right = _sample_outer(sampler, ax, az, right_x, right_z, outer)
                b_left, b_right = _sample_outer(sampler, bx, bz, right_x, right_z, outer)
            except ValueError:
                stats["shoulder_sample_failures"] += 1
                continue

            # Endpoint cross-sections must still show at least one side with the
            # tagged physical relation. Otherwise a coarse midpoint alone is not
            # enough evidence to reshape this fragment.
            endpoint_deltas = (
                a_left - ay, a_right - ay,
                b_left - by, b_right - by,
            )
            if kind == "source_cutting":
                endpoint_supported = max(endpoint_deltas) >= MIN_SUPPORT_RELIEF_M
            else:
                endpoint_supported = min(endpoint_deltas) <= -MIN_SUPPORT_RELIEF_M
            if not endpoint_supported:
                stats["source_records_deferred_endpoint_relief"] += 1
                stats[f"deferred_endpoint_{kind}"] += 1
                continue

            records_by_tile[(tx, tz)].append({
                "id": "%s:%s:%s" % (
                    str(record.get("source_way", "")),
                    str(record.get("source_segment_index", 0)), kind),
                "source_way": str(record.get("source_way", "")),
                "source_segment_index": int(record.get("source_segment_index", 0)),
                "source_node_a": int(record.get("source_node_a", 0)),
                "source_node_b": int(record.get("source_node_b", 0)),
                "classification": kind,
                "source_reason": str(record.get("reason", "")),
                "geometry_reason": reason,
                "highway": str(record.get("highway", "")),
                "name": str(record.get("name", "")),
                "ref": str(record.get("ref", "")),
                "a": [round(ax, 6), round(ay, 6), round(az, 6)],
                "b": [round(bx, 6), round(by, 6), round(bz, 6)],
                "right": [round(right_x, 9), round(right_z, 9)],
                "road_half_width_m": round(road_half, 3),
                "outer_half_width_m": round(outer, 3),
                "mask_half_width_m": round(outer + OUTER_OVERLAP_M, 3),
                "outer_left_y": [round(a_left, 6), round(b_left, 6)],
                "outer_right_y": [round(a_right, 6), round(b_right, 6)],
                "width_source": str(record.get("width_source", "")),
                "terrain_policy": "source-tagged earthwork + DEM-supported side-slope replacement",
            })
            stats["geometry_fragments"] += 1
            stats[f"geometry_{kind}"] += 1
            if str(record.get("width_source", "")) == "source":
                stats["source_width_fragments"] += 1
            else:
                stats["fallback_width_fragments"] += 1

    staging = output_root.with_name(output_root.name + ".staging")
    if staging.exists():
        shutil.rmtree(staging)
    (staging / "tiles").mkdir(parents=True)
    tiles = []
    for (tx, tz), records in sorted(records_by_tile.items()):
        records.sort(key=lambda item: item["id"])
        relative = f"tiles/tile_{tx}_{tz}.json"
        (staging / relative).write_text(
            json.dumps({"tile": [tx, tz], "earthworks": records}, separators=(",", ":")),
            encoding="utf-8",
        )
        tiles.append({"x": tx, "z": tz, "file": relative, "records": len(records)})

    manifest = {
        "format": 1,
        "source": "explicit OSM cutting/embankment records + DEM cross-section support",
        "policy": "source tags are necessary but not sufficient; DEM-only candidates are excluded and source-tagged fragments with unresolved relief are deferred",
        "minimum_support_relief_m": MIN_SUPPORT_RELIEF_M,
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
    parser.add_argument("terrain_root", type=Path)
    parser.add_argument("earthworks_root", type=Path)
    parser.add_argument("output_root", type=Path)
    args = parser.parse_args()
    manifest = compile_geometry(args.terrain_root, args.earthworks_root, args.output_root)
    print("YARDMAN_SOURCE_ROAD_EARTHWORK_GEOMETRY_PASS", json.dumps(manifest["stats"], sort_keys=True),
          "tiles=", len(manifest["tiles"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
