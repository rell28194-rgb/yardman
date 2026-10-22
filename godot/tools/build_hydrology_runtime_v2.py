#!/usr/bin/env python3
"""Compile Yardman's audited hydrology truth into a mobile runtime contract.

Runtime v2 keeps the DEM-registered endpoint elevations, provenance, stable
segment identity and evidence-gated road/water crossing semantics. It does not
turn the inferred channel-depth seed or a morphology sidecar into DEM mutation
permission. Terrain mutation remains a separate approved-operation contract.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import shutil
from collections import Counter, defaultdict
from pathlib import Path


def _canonical(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")


def _distance_to_segment(px: float, pz: float, ax: float, az: float, bx: float, bz: float) -> float:
    dx, dz = bx - ax, bz - az
    length_sq = dx * dx + dz * dz
    if length_sq <= 1e-12:
        return math.hypot(px - ax, pz - az)
    t = max(0.0, min(1.0, ((px - ax) * dx + (pz - az) * dz) / length_sq))
    return math.hypot(px - (ax + dx * t), pz - (az + dz * t))


def _load_segments(root: Path) -> tuple[dict, list[dict]]:
    manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
    if int(manifest.get("format", 0)) != 3 or str(manifest.get("crs", "")) != "EPSG:3448":
        raise ValueError("runtime v2 requires DEM-registered hydrology format 3 in EPSG:3448")
    fields = list(manifest.get("record_format", []))
    required = {"ax", "ay", "az", "bx", "by", "bz", "source_way", "waterway", "width_m",
                "width_source", "grade_permille", "channel_seed_depth_m", "channel_depth_source", "segment_key"}
    if not required.issubset(fields):
        raise ValueError("hydrology record format lacks runtime-v2 truth fields")
    segments: list[dict] = []
    seen: set[str] = set()
    for tile in manifest.get("tiles", []):
        payload = json.loads((root / str(tile["file"])).read_text(encoding="utf-8"))
        tile_coord = [int(tile["x"]), int(tile["z"])]
        for raw in payload.get("segments", []):
            record = dict(zip(fields, raw))
            key = str(record["segment_key"])
            if key in seen:
                raise ValueError(f"duplicate hydrology segment key: {key}")
            seen.add(key)
            record["tile"] = tile_coord
            segments.append(record)
    expected = int(manifest.get("stats", {}).get("segments", len(segments)))
    if len(segments) != expected:
        raise ValueError(f"hydrology segment count mismatch: manifest={expected} actual={len(segments)}")
    return manifest, segments


def _load_truth(root: Path, segments: list[dict]) -> dict[str, dict]:
    path = root / "truth-sidecar.json"
    if not path.is_file():
        raise ValueError("hydrology truth sidecar missing")
    payload = json.loads(path.read_text(encoding="utf-8"))
    decisions: dict[str, dict] = {}
    for record in payload.get("segments", []):
        key = str(record.get("segment_key", ""))
        if not key or key in decisions:
            raise ValueError(f"invalid or duplicate truth-sidecar segment key: {key}")
        decisions[key] = dict(record.get("decision", {}))
    segment_keys = {str(record["segment_key"]) for record in segments}
    if set(decisions) != segment_keys:
        raise ValueError("truth-sidecar coverage does not exactly match hydrology segments")
    return decisions


def _load_crossings(root: Path, segments: list[dict], tolerance_m: float = 0.10) -> tuple[dict[str, list[dict]], Counter]:
    path = root / "crossings.json"
    if not path.is_file():
        raise ValueError("hydrology crossing inventory missing")
    payload = json.loads(path.read_text(encoding="utf-8"))
    by_way: dict[str, list[dict]] = defaultdict(list)
    for segment in segments:
        by_way[str(segment["source_way"])].append(segment)
    for records in by_way.values():
        records.sort(key=lambda item: str(item["segment_key"]))

    attached: dict[str, list[dict]] = defaultdict(list)
    stats: Counter = Counter()
    for crossing in payload.get("crossings", []):
        way = str(crossing.get("water_source_way", ""))
        candidates = by_way.get(way, [])
        if not candidates:
            raise ValueError(f"crossing references unknown hydrology way: {way}")
        px, pz = float(crossing["x"]), float(crossing["z"])
        ranked = []
        for segment in candidates:
            distance = _distance_to_segment(px, pz, float(segment["ax"]), float(segment["az"]),
                                            float(segment["bx"]), float(segment["bz"]))
            ranked.append((distance, str(segment["segment_key"]), segment))
        distance, _key, segment = min(ranked, key=lambda item: (item[0], item[1]))
        if distance > tolerance_m:
            raise ValueError(f"crossing/segment reconciliation exceeded {tolerance_m} m: {distance:.6f} {way}")
        compact = {
            "x": round(px, 3),
            "z": round(pz, 3),
            "kind": str(crossing.get("kind", "unknown")),
            "status": str(crossing.get("status", "unresolved")),
            "terrain_action": str(crossing.get("terrain_action", "none")),
            "road_edge": str(crossing.get("road_edge", "")),
            "evidence": list(crossing.get("evidence", [])),
            "source_crossing_evidence": dict(crossing.get("source_crossing_evidence", {})),
        }
        attached[str(segment["segment_key"])].append(compact)
        stats["crossings"] += 1
        stats[f"kind_{compact['kind']}"] += 1
        stats[f"status_{compact['status']}"] += 1
    for records in attached.values():
        records.sort(key=lambda item: (item["x"], item["z"], item["road_edge"], item["kind"]))
    return dict(attached), stats


def compile_runtime_v2(source_root: Path, output_root: Path) -> dict:
    manifest, segments = _load_segments(source_root)
    truth = _load_truth(source_root, segments)
    crossings, crossing_stats = _load_crossings(source_root, segments)
    tile_size = float(manifest["tile_size"])
    if not math.isfinite(tile_size) or tile_size <= 0.0:
        raise ValueError("invalid hydrology tile size")

    staging = output_root.with_name(output_root.name + ".staging")
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)

    records_by_tile: dict[tuple[int, int], list[list]] = defaultdict(list)
    stats: Counter = Counter()
    for segment in segments:
        tx, tz = map(int, segment["tile"])
        key = str(segment["segment_key"])
        decision = truth[key]
        status = str(decision.get("status", "blocked"))
        morphology_family = str(decision.get("morphology_family", "none"))
        if status == "approved":
            stats["morphology_evidence_approved"] += 1
        else:
            stats["morphology_evidence_blocked"] += 1
        local_ax = float(segment["ax"]) - tx * tile_size
        local_az = float(segment["az"]) - tz * tile_size
        local_bx = float(segment["bx"]) - tx * tile_size
        local_bz = float(segment["bz"]) - tz * tile_size
        if not all(math.isfinite(value) for value in (local_ax, local_az, local_bx, local_bz,
                                                       float(segment["ay"]), float(segment["by"]))):
            raise ValueError(f"non-finite runtime hydrology geometry: {key}")
        attached_crossings = crossings.get(key, [])
        record = [
            round(local_ax, 6), round(float(segment["ay"]), 6), round(local_az, 6),
            round(local_bx, 6), round(float(segment["by"]), 6), round(local_bz, 6),
            str(segment["source_way"]), str(segment["waterway"]), str(segment.get("name", "")),
            round(float(segment["width_m"]), 3), str(segment["width_source"]),
            bool(segment.get("intermittent", False)), bool(segment.get("tidal", False)),
            round(float(segment["grade_permille"]), 3), round(float(segment["channel_seed_depth_m"]), 3),
            str(segment["channel_depth_source"]), key, status, morphology_family, attached_crossings,
        ]
        records_by_tile[(tx, tz)].append(record)
        stats["segments"] += 1
        stats[f"class_{segment['waterway']}"] += 1
        if attached_crossings:
            stats["segments_with_crossings"] += 1

    tile_entries = []
    for (tx, tz), records in sorted(records_by_tile.items()):
        records.sort(key=lambda item: item[16])
        payload = {"format_version": 2, "tile": [tx, tz], "segments": records}
        data = _canonical(payload)
        filename = f"tile_{tx}_{tz}.json"
        (staging / filename).write_bytes(data)
        tile_entries.append({
            "x": tx, "z": tz, "file": filename, "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(), "segments": len(records),
        })

    runtime_manifest = {
        "format_version": 2,
        "pack_id": "jamaica_hydrology_reconciled_v2",
        "crs": "EPSG:3448",
        "axis": manifest.get("axis", "X east, Y elevation, Z south; real metres"),
        "origin": manifest["origin"],
        "tile_size": tile_size,
        "source": manifest.get("source", "OpenStreetMap waterways registered to Yardman terrain"),
        "terrain_source": manifest.get("terrain_source", "Yardman terrain DEM"),
        "record_format": [
            "local_ax", "ay", "local_az", "local_bx", "by", "local_bz",
            "source_way", "waterway", "name", "width_m", "width_source",
            "intermittent", "tidal", "grade_permille", "channel_seed_depth_m",
            "channel_depth_source", "segment_key", "morphology_status", "morphology_family", "crossings",
        ],
        "render_policy": {
            "active_tile_radius": 1,
            "max_active_tiles": 9,
            "max_vertices_per_tile": 12000,
            "collision": False,
            "planar_reflections": False,
            "shadows": False,
            "use_compiled_dem_elevation": True,
            "unresolved_crossing_policy": "do_not_invent_structure",
        },
        "terrain_mutation_policy": "runtime pack grants no DEM mutation permission; consume a separately approved terrain-operation contract",
        "stats": dict(sorted({**stats, **crossing_stats}.items())),
        "tiles": tile_entries,
    }
    (staging / "manifest.json").write_bytes(_canonical(runtime_manifest))
    if output_root.exists():
        shutil.rmtree(output_root)
    staging.replace(output_root)
    return runtime_manifest


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source_root", type=Path)
    parser.add_argument("output_root", type=Path)
    args = parser.parse_args()
    result = compile_runtime_v2(args.source_root, args.output_root)
    print("YARDMAN_HYDROLOGY_RUNTIME_V2_PASS", json.dumps(result["stats"], sort_keys=True),
          "tiles=", len(result["tiles"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
