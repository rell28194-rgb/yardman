#!/usr/bin/env python3
"""Evaluate Yardman's short-horizon stream-priority policy on a preserved national Jamaica build.

Input must be the ZIP artifact emitted by Yardman Production Jamaica Data workflow.
The evaluator derives approach traces from real compiled road graph geometry and
speed limits. No synthetic road geometry is used.
"""
from __future__ import annotations
import argparse, hashlib, json, math, zipfile
from pathlib import Path

TILE = 4096.0
RADIUS = 2
LEADS = (0.5, 1.0, 2.0, 3.0, 5.0)
PREDICTION_HORIZON_S = 2.0
PREDICTION_WEIGHT = 0.20
EXPECTED_ARTIFACT_SHA256 = "885ed9a1dcfdbb52c33e50400a003fbc96983445fde62d87ed5ef5f0bca8d4d9"

def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def tile_of(x: float, z: float) -> tuple[int, int]:
    return math.floor(x / TILE), math.floor(z / TILE)

def candidates(current: tuple[int, int]) -> list[tuple[int, int]]:
    cx, cz = current
    return [(cx + dx, cz + dz)
            for dz in range(-RADIUS, RADIUS + 1)
            for dx in range(-RADIUS, RADIUS + 1)
            if dx != 0 or dz != 0]

def baseline_score(tile: tuple[int, int], current: tuple[int, int]) -> float:
    dx = tile[0] - current[0]
    dz = tile[1] - current[1]
    return float(dx * dx + dz * dz)

def distance2_to_aabb(px: float, pz: float, tile: tuple[int, int]) -> float:
    x0, z0 = tile[0] * TILE, tile[1] * TILE
    x1, z1 = x0 + TILE, z0 + TILE
    dx = 0.0 if x0 <= px <= x1 else (x0 - px if px < x0 else px - x1)
    dz = 0.0 if z0 <= pz <= z1 else (z0 - pz if pz < z0 else pz - z1)
    return dx * dx + dz * dz

def predictive_score(tile, x, z, vx, vz) -> float:
    return (
        distance2_to_aabb(x, z, tile)
        + PREDICTION_WEIGHT * distance2_to_aabb(
            x + vx * PREDICTION_HORIZON_S,
            z + vz * PREDICTION_HORIZON_S,
            tile,
        )
    )

def expected_rank(target, pool, score_fn) -> float:
    scores = {tile: score_fn(tile) for tile in pool}
    target_score = scores[target]
    less = sum(value < target_score - 1e-9 for value in scores.values())
    equal_other = sum(abs(value - target_score) <= 1e-9 for value in scores.values()) - 1
    return 1.0 + less + 0.5 * equal_other

def first_crossing(x0, z0, x1, z1):
    current = tile_of(x0, z0)
    dx, dz = x1 - x0, z1 - z0
    ts = []
    if dx > 1e-9:
        ts.append(((current[0] + 1) * TILE - x0) / dx)
    elif dx < -1e-9:
        ts.append((current[0] * TILE - x0) / dx)
    if dz > 1e-9:
        ts.append(((current[1] + 1) * TILE - z0) / dz)
    elif dz < -1e-9:
        ts.append((current[1] * TILE - z0) / dz)
    ts = [t for t in ts if 1e-9 < t <= 1.0 + 1e-9]
    if not ts:
        return None
    t = min(ts)
    t_after = min(1.0, t + 1e-7)
    target = tile_of(x0 + dx * t_after, z0 + dz * t_after)
    if target == current:
        target = tile_of(x0 + dx * min(1.0, t + 1e-5), z0 + dz * min(1.0, t + 1e-5))
    return None if target == current else (t, target)

def point_at_distance(path, cumulative, distance):
    import bisect
    if distance <= 0.0:
        index, t = 0, 0.0
    elif distance >= cumulative[-1]:
        index, t = len(path) - 2, 1.0
    else:
        index = max(0, bisect.bisect_right(cumulative, distance) - 1)
        segment_length = cumulative[index + 1] - cumulative[index]
        t = 0.0 if segment_length <= 1e-9 else (distance - cumulative[index]) / segment_length
    a, b = path[index], path[index + 1]
    x = a[0] + (b[0] - a[0]) * t
    z = a[2] + (b[2] - a[2]) * t
    dx, dz = b[0] - a[0], b[2] - a[2]
    length = math.hypot(dx, dz)
    return x, z, (dx / length if length else 0.0), (dz / length if length else 0.0)

def fold_for_way(source_way: str) -> int:
    return int(hashlib.sha256(source_way.encode()).hexdigest()[:8], 16) % 5

def metric(rows):
    baseline = sum(r["baseline_rank"] for r in rows) / len(rows)
    candidate = sum(r["candidate_rank"] for r in rows) / len(rows)
    return {
        "traces": len(rows),
        "source_ways": len({r["source_way"] for r in rows}),
        "edges": len({r["edge_id"] for r in rows}),
        "baseline_mean_rank": baseline,
        "candidate_mean_rank": candidate,
        "rank_improvement": (baseline - candidate) / baseline,
        "candidate_top1_rate": sum(r["candidate_rank"] <= 1.0 for r in rows) / len(rows),
        "candidate_top4_rate": sum(r["candidate_rank"] <= 4.0 for r in rows) / len(rows),
        "candidate_worse_rate": sum(r["candidate_rank"] > r["baseline_rank"] + 1e-9 for r in rows) / len(rows),
    }

def evaluate(artifact: Path):
    artifact_sha = sha256_file(artifact)
    if artifact_sha != EXPECTED_ARTIFACT_SHA256:
        raise RuntimeError(f"artifact SHA mismatch: {artifact_sha}")
    with zipfile.ZipFile(artifact) as archive:
        manifest = json.loads(archive.read("output/roads/manifest.json"))
        if float(manifest["tile_size"]) != TILE:
            raise RuntimeError("unexpected national tile size")
        edge_names = sorted(name for name in archive.namelist()
                            if name.startswith("output/roads/graph/edges_") and name.endswith(".json"))
        edges = {}
        for name in edge_names:
            edges.update(json.loads(archive.read(name)))

    rows = []
    for edge in edges.values():
        speed = edge.get("speed_limit_mps")
        if not isinstance(speed, (int, float)) or not math.isfinite(speed) or speed <= 0.0:
            continue
        if len(edge.get("tiles", [])) <= 1 or len(edge.get("path", [])) < 2:
            continue
        directions = []
        direction = int(edge.get("direction", 0))
        if direction >= 0:
            directions.append(edge["path"])
        if direction <= 0:
            directions.append(list(reversed(edge["path"])))
        for path in directions:
            cumulative = [0.0]
            for a, b in zip(path, path[1:]):
                cumulative.append(cumulative[-1] + math.hypot(b[0] - a[0], b[2] - a[2]))
            for index, (a, b) in enumerate(zip(path, path[1:])):
                crossing = first_crossing(a[0], a[2], b[0], b[2])
                if crossing is None:
                    continue
                fraction, target = crossing
                segment_length = math.hypot(b[0] - a[0], b[2] - a[2])
                crossing_distance = cumulative[index] + segment_length * fraction
                for lead in LEADS:
                    sample_distance = crossing_distance - speed * lead
                    if sample_distance < 0.0:
                        continue
                    x, z, ux, uz = point_at_distance(path, cumulative, sample_distance)
                    current = tile_of(x, z)
                    pool = candidates(current)
                    if current == target or target not in pool:
                        continue
                    vx, vz = ux * speed, uz * speed
                    rows.append({
                        "edge_id": edge["id"],
                        "source_way": edge["source_way"],
                        "baseline_rank": expected_rank(target, pool, lambda tile: baseline_score(tile, current)),
                        "candidate_rank": expected_rank(target, pool, lambda tile: predictive_score(tile, x, z, vx, vz)),
                    })
    overall = metric(rows)
    folds = [metric([r for r in rows if fold_for_way(r["source_way"]) == fold]) for fold in range(5)]
    passed = (
        overall["traces"] >= 6000
        and overall["rank_improvement"] >= 0.55
        and overall["candidate_top1_rate"] >= 0.97
        and overall["candidate_top4_rate"] == 1.0
        and overall["candidate_worse_rate"] == 0.0
        and min(f["rank_improvement"] for f in folds) >= 0.55
        and max(f["candidate_worse_rate"] for f in folds) == 0.0
    )
    return {
        "schema_version": 1,
        "artifact_sha256": artifact_sha,
        "source_pbf_sha256": manifest.get("source_sha256"),
        "manifest_stats": {
            "tiles": manifest.get("stats", {}).get("tiles"),
            "graph_edges": manifest.get("stats", {}).get("graph_edges"),
            "graph_nodes": manifest.get("stats", {}).get("graph_nodes"),
        },
        "overall": overall,
        "source_way_holdout_folds": folds,
        "passed": passed,
    }

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("artifact_zip", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    report = evaluate(args.artifact_zip)
    text = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
    print(
        "YARDMAN_RDX_STREAM_PRIORITY_NATIONAL "
        f"traces={report['overall']['traces']} "
        f"baseline={report['overall']['baseline_mean_rank']:.4f} "
        f"candidate={report['overall']['candidate_mean_rank']:.4f} "
        f"improvement={report['overall']['rank_improvement']:.4f} "
        f"top1={report['overall']['candidate_top1_rate']:.4f} "
        f"top4={report['overall']['candidate_top4_rate']:.4f} "
        f"worse={report['overall']['candidate_worse_rate']:.4f} "
        f"result={'PASS' if report['passed'] else 'FAIL'}"
    )
    return 0 if report["passed"] else 1

if __name__ == "__main__":
    raise SystemExit(main())
