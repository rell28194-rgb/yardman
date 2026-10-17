#!/usr/bin/env python3
"""Compile terrain-integrated open-channel corridors from hydrology truth.

The 64 m national DEM is too coarse to lower its grid vertices directly for a
5-20 m river/stream. This compiler therefore produces high-resolution channel
corridors registered to the immutable OSM centerline and local DEM. Runtime can
cut the coarse land surface only inside each corridor and replace that hole with
bank/bed geometry.

No road structure is invented here. Channel carving is suspended around any
road/water crossing whose source evidence does not establish that the waterway
can remain open beneath/above the road. Source-tagged road bridges and road
tunnels allow the open channel to continue; unresolved crossings and fords are
protected for a later structure/grade reconstruction pass.
"""
from __future__ import annotations

import argparse
import json
import math
import shutil
from collections import Counter, defaultdict
from pathlib import Path

OPEN_CHANNEL_CLASSES = {"river", "stream", "canal"}
ALLOW_OPEN_THROUGH_CROSSING = {"road_bridge", "road_tunnel"}
PROTECTED_CROSSING_CLASSES = {
    "ford",
    "layer_grade_separation",
    "at_grade_shared_node_unresolved",
    "geometric_crossing_unresolved",
    "linear_overlap_unresolved",
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


def bank_margin_m(width_m: float) -> float:
    return max(2.5, min(12.0, float(width_m) * 0.40))


def crossing_protection_radius_m(road_class: str, channel_width_m: float) -> float:
    road_width = ROAD_WIDTH_FALLBACK_M.get(str(road_class), 5.8)
    return max(7.0, road_width * 0.75 + channel_width_m * 0.50 + 2.0)


def conservative_bed_height(center_y: float, left_y: float, right_y: float, width_m: float) -> float:
    """Create a modest bed inset without pretending we have surveyed bathymetry.

    Existing DEM valley relief is preserved. Only a small additional inset is
    added so the replacement bed is actually below the coarse terrain skin.
    The extra cut is capped at 1.5 m and recorded as inferred in the manifest.
    """
    values = (center_y, left_y, right_y, width_m)
    if not all(math.isfinite(float(v)) for v in values):
        raise ValueError("non-finite channel profile")
    if width_m <= 0.0:
        raise ValueError("channel width must be positive")
    extra = max(0.15, min(0.80, width_m * 0.020))
    bank_floor = min(left_y, right_y)
    target = min(center_y - extra, bank_floor - 0.10)
    return max(center_y - 1.50, target)


def _circle_interval(a: tuple[float, float], b: tuple[float, float], center: tuple[float, float], radius: float):
    dx, dz = b[0] - a[0], b[1] - a[1]
    fx, fz = a[0] - center[0], a[1] - center[1]
    aa = dx * dx + dz * dz
    if aa <= 1e-12:
        return None
    bb = 2.0 * (fx * dx + fz * dz)
    cc = fx * fx + fz * fz - radius * radius
    disc = bb * bb - 4.0 * aa * cc
    if disc < 0.0:
        return None
    root = math.sqrt(max(0.0, disc))
    t0 = (-bb - root) / (2.0 * aa)
    t1 = (-bb + root) / (2.0 * aa)
    lo, hi = max(0.0, min(t0, t1)), min(1.0, max(t0, t1))
    if hi - lo <= 1e-9:
        # Segment can be entirely inside the circle without crossing its edge.
        if cc <= 0.0 and (fx + dx) ** 2 + (fz + dz) ** 2 <= radius * radius:
            return (0.0, 1.0)
        return None
    return (lo, hi)


def visible_intervals(
    a: tuple[float, float], b: tuple[float, float],
    protections: list[tuple[float, float, float]],
) -> list[tuple[float, float]]:
    """Subtract protected crossing circles from one source segment."""
    blocked = []
    for x, z, radius in protections:
        interval = _circle_interval(a, b, (x, z), radius)
        if interval is not None:
            blocked.append(interval)
    if not blocked:
        return [(0.0, 1.0)]
    blocked.sort()
    merged = []
    for lo, hi in blocked:
        if not merged or lo > merged[-1][1] + 1e-9:
            merged.append([lo, hi])
        else:
            merged[-1][1] = max(merged[-1][1], hi)
    visible = []
    cursor = 0.0
    for lo, hi in merged:
        if lo > cursor + 1e-7:
            visible.append((cursor, lo))
        cursor = max(cursor, hi)
    if cursor < 1.0 - 1e-7:
        visible.append((cursor, 1.0))
    return visible


def _lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def _load_crossing_protections(crossing_root: Path) -> dict[str, list[dict]]:
    result: dict[str, list[dict]] = defaultdict(list)
    manifest_path = crossing_root / "manifest.json"
    if not manifest_path.is_file():
        return result
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    for item in manifest.get("tiles", []):
        payload = json.loads((crossing_root / str(item["file"])).read_text(encoding="utf-8"))
        for record in payload.get("crossings", []):
            classification = str(record.get("classification", ""))
            if classification in ALLOW_OPEN_THROUGH_CROSSING:
                continue
            # Culvert/underground source ways are already excluded by hydrology
            # record semantics. Keep any duplicate crossing record out here.
            if classification in {"waterway_culvert", "waterway_underground"}:
                continue
            if classification not in PROTECTED_CROSSING_CLASSES:
                classification = "geometric_crossing_unresolved"
            result[str(record.get("waterway_way", ""))].append({
                "x": float(record["x"]),
                "z": float(record["z"]),
                "road_class": str(record.get("road_class", "")),
                "classification": classification,
            })
    return result


def compile_channels(terrain_root: Path, hydrology_root: Path, crossing_root: Path, output_root: Path) -> dict:
    from build_terrain import TerrainSampler

    hydro_manifest = json.loads((hydrology_root / "manifest.json").read_text(encoding="utf-8"))
    if int(hydro_manifest.get("format", 0)) < 2:
        raise ValueError("Hydrology format 2 with crossing semantics is required")
    tile_size = float(hydro_manifest["tile_size"])
    sampler = TerrainSampler(terrain_root)
    protections = _load_crossing_protections(crossing_root)
    outputs: dict[tuple[int, int], list[dict]] = defaultdict(list)
    stats: Counter = Counter()

    for tile in hydro_manifest.get("tiles", []):
        tx, tz = int(tile["x"]), int(tile["z"])
        payload = json.loads((hydrology_root / str(tile["file"])).read_text(encoding="utf-8"))
        for raw in payload.get("segments", []):
            stats["source_segments_seen"] += 1
            if not isinstance(raw, list) or len(raw) < 22:
                stats["rejected_record_format"] += 1
                continue
            waterway = str(raw[7])
            if waterway not in OPEN_CHANNEL_CLASSES:
                stats["engineered_small_drainage_deferred"] += 1
                continue
            if bool(raw[20]):
                stats["underground_segments_excluded"] += 1
                continue
            ax, az = float(raw[0]), float(raw[2])
            bx, bz = float(raw[3]), float(raw[5])
            dx, dz = bx - ax, bz - az
            length = math.hypot(dx, dz)
            if length <= 0.05:
                stats["degenerate_segments"] += 1
                continue
            width_m = max(0.5, float(raw[9]))
            source_way = str(raw[6])
            segment_protections = []
            for crossing in protections.get(source_way, []):
                radius = crossing_protection_radius_m(crossing["road_class"], width_m)
                # Cheap bbox reject before solving the line/circle interval.
                if crossing["x"] < min(ax, bx) - radius or crossing["x"] > max(ax, bx) + radius:
                    continue
                if crossing["z"] < min(az, bz) - radius or crossing["z"] > max(az, bz) + radius:
                    continue
                segment_protections.append((crossing["x"], crossing["z"], radius))
            intervals = visible_intervals((ax, az), (bx, bz), segment_protections)
            if segment_protections:
                stats["segments_near_protected_crossing"] += 1
            if not intervals:
                stats["segments_fully_protected"] += 1
                continue
            right_x, right_z = -dz / length, dx / length
            cut_half = width_m * 0.5 + bank_margin_m(width_m)
            for part_index, (t0, t1) in enumerate(intervals):
                if t1 - t0 <= 1e-6:
                    continue
                p = (ax + dx * t0, az + dz * t0)
                q = (ax + dx * t1, az + dz * t1)
                center_a = float(sampler(p[0], p[1]))
                center_b = float(sampler(q[0], q[1]))
                left_a = float(sampler(p[0] + right_x * cut_half, p[1] + right_z * cut_half))
                right_a = float(sampler(p[0] - right_x * cut_half, p[1] - right_z * cut_half))
                left_b = float(sampler(q[0] + right_x * cut_half, q[1] + right_z * cut_half))
                right_b = float(sampler(q[0] - right_x * cut_half, q[1] - right_z * cut_half))
                profile_values = (center_a, center_b, left_a, right_a, left_b, right_b)
                if not all(math.isfinite(v) for v in profile_values):
                    stats["nonfinite_profiles"] += 1
                    continue
                bed_a = conservative_bed_height(center_a, left_a, right_a, width_m)
                bed_b = conservative_bed_height(center_b, left_b, right_b, width_m)
                water_depth = max(0.08, min(0.45, width_m * 0.012))
                outputs[(tx, tz)].append({
                    "id": f"{source_way}:{int(raw[13])}:{part_index}",
                    "source_way": source_way,
                    "source_segment_index": int(raw[13]),
                    "source_node_a": int(raw[14]),
                    "source_node_b": int(raw[15]),
                    "waterway": waterway,
                    "name": str(raw[8]),
                    "width_m": round(width_m, 3),
                    "width_source": str(raw[10]),
                    "intermittent": bool(raw[11]),
                    "tidal": bool(raw[12]),
                    "a": [round(p[0], 6), round(center_a, 6), round(p[1], 6)],
                    "b": [round(q[0], 6), round(center_b, 6), round(q[1], 6)],
                    "right": [round(right_x, 9), round(right_z, 9)],
                    "cut_half_width_m": round(cut_half, 3),
                    "bank_left_y": [round(left_a, 6), round(left_b, 6)],
                    "bank_right_y": [round(right_a, 6), round(right_b, 6)],
                    "bed_y": [round(bed_a, 6), round(bed_b, 6)],
                    "water_y": [round(bed_a + water_depth, 6), round(bed_b + water_depth, 6)],
                    "incision_source": "DEM lateral relief + conservative unsurveyed inset",
                    "protected_crossings_applied": len(segment_protections),
                })
                stats["channel_fragments"] += 1
                stats[f"class_{waterway}_fragments"] += 1
                if str(raw[10]) == "source":
                    stats["source_width_fragments"] += 1
                else:
                    stats["fallback_width_fragments"] += 1
                if bool(raw[11]):
                    stats["intermittent_fragments"] += 1
                if t0 > 1e-7 or t1 < 1.0 - 1e-7:
                    stats["fragments_clipped_for_crossing"] += 1

    staging = output_root.with_name(output_root.name + ".staging")
    if staging.exists():
        shutil.rmtree(staging)
    (staging / "tiles").mkdir(parents=True)
    tiles = []
    for (tx, tz), records in sorted(outputs.items()):
        records.sort(key=lambda item: item["id"])
        relative = f"tiles/tile_{tx}_{tz}.json"
        (staging / relative).write_text(
            json.dumps({"tile": [tx, tz], "channels": records}, separators=(",", ":")),
            encoding="utf-8",
        )
        tiles.append({"x": tx, "z": tz, "file": relative, "channels": len(records)})

    manifest = {
        "format": 1,
        "source": "Yardman hydrology format 2 + terrain DEM + source-backed road/water crossing evidence",
        "geometry_policy": "high-resolution replacement corridors; base 64 m DEM vertices remain immutable",
        "incision_source": "DEM lateral relief + conservative unsurveyed inset capped at 1.5 m",
        "crossing_policy": "open under source road bridges/tunnels; suspend around ford/unresolved crossings; exclude underground/culvert waterways",
        "deferred_classes": ["drain", "ditch"],
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
    parser.add_argument("hydrology_root", type=Path)
    parser.add_argument("crossing_root", type=Path)
    parser.add_argument("output_root", type=Path)
    args = parser.parse_args()
    manifest = compile_channels(args.terrain_root, args.hydrology_root, args.crossing_root, args.output_root)
    print("YARDMAN_HYDROLOGY_CHANNELS_PASS", json.dumps(manifest["stats"], sort_keys=True),
          "tiles=", len(manifest["tiles"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
