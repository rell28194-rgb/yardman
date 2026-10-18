#!/usr/bin/env python3
"""Frozen-trace evaluator for Yardman road/terrain stream queue priority.

This evaluator is intentionally independent from the runtime implementation. It
compares the current coarse tile-index distance metric with a candidate metric
that scores exact distance to each 4096 m tile AABB at the current player
position plus short-horizon predicted positions. The candidate set/residency
radius is identical for both strategies.
"""

from __future__ import annotations

import json
import math
from dataclasses import dataclass
from pathlib import Path

TILE_SIZE = 4096.0
RADIUS = 2
HORIZONS = ((2.0, 5.0), (10.0, 4.0), (30.0, 3.0), (60.0, 2.0), (90.0, 1.0))

@dataclass(frozen=True)
class Sample:
    name: str
    x: float
    z: float
    vx: float
    vz: float

SAMPLES = (
    Sample("east-edge-a", 3980.0, 2048.0, 38.0, 0.0),
    Sample("east-edge-b", 4050.0, 2048.0, 38.0, 0.0),
    Sample("west-edge-a", 116.0, 2048.0, -32.0, 0.0),
    Sample("west-edge-b", 35.0, 2048.0, -32.0, 0.0),
    Sample("south-edge-a", 2048.0, 3970.0, 0.0, 34.0),
    Sample("south-edge-b", 2048.0, 4055.0, 0.0, 34.0),
    Sample("north-edge-a", 2048.0, 130.0, 0.0, -30.0),
    Sample("north-edge-b", 2048.0, 40.0, 0.0, -30.0),
    Sample("diag-se-a", 3950.0, 3960.0, 28.0, 31.0),
    Sample("diag-se-b", 4050.0, 4040.0, 28.0, 31.0),
    Sample("diag-nw-a", 150.0, 120.0, -26.0, -29.0),
    Sample("diag-nw-b", 55.0, 45.0, -26.0, -29.0),
)


def tile_for(x: float, z: float) -> tuple[int, int]:
    return math.floor(x / TILE_SIZE), math.floor(z / TILE_SIZE)


def candidates(current: tuple[int, int]) -> list[tuple[int, int]]:
    cx, cz = current
    return [
        (cx + dx, cz + dz)
        for dz in range(-RADIUS, RADIUS + 1)
        for dx in range(-RADIUS, RADIUS + 1)
        if dx != 0 or dz != 0
    ]


def baseline_score(tile: tuple[int, int], current: tuple[int, int]) -> float:
    dx = tile[0] - current[0]
    dz = tile[1] - current[1]
    return float(dx * dx + dz * dz)


def distance2_to_aabb(px: float, pz: float, tile: tuple[int, int]) -> float:
    x0 = tile[0] * TILE_SIZE
    z0 = tile[1] * TILE_SIZE
    x1 = x0 + TILE_SIZE
    z1 = z0 + TILE_SIZE
    dx = 0.0 if x0 <= px <= x1 else (x0 - px if px < x0 else px - x1)
    dz = 0.0 if z0 <= pz <= z1 else (z0 - pz if pz < z0 else pz - z1)
    return dx * dx + dz * dz


def predictive_score(tile: tuple[int, int], s: Sample) -> float:
    # Current distance dominates so the heuristic remains conservative near the
    # player. Prediction only breaks coarse 4 km tile ties in the travel direction.
    return (
        1.00 * distance2_to_aabb(s.x, s.z, tile)
        + 0.60 * distance2_to_aabb(s.x + s.vx * 10.0, s.z + s.vz * 10.0, tile)
        + 0.30 * distance2_to_aabb(s.x + s.vx * 30.0, s.z + s.vz * 30.0, tile)
    )


def expected_rank(target: tuple[int, int], pool: list[tuple[int, int]], scores: dict[tuple[int, int], float]) -> float:
    target_score = scores[target]
    less = sum(1 for tile in pool if scores[tile] < target_score - 1e-9)
    equal_other = sum(1 for tile in pool if abs(scores[tile] - target_score) <= 1e-9) - 1
    return 1.0 + less + 0.5 * equal_other


def evaluate() -> dict[str, object]:
    weighted_baseline = 0.0
    weighted_candidate = 0.0
    total_weight = 0.0
    baseline_top4_weight = 0.0
    candidate_top4_weight = 0.0
    observations = 0
    details: list[dict[str, object]] = []

    for sample in SAMPLES:
        current = tile_for(sample.x, sample.z)
        pool = candidates(current)
        baseline_scores = {tile: baseline_score(tile, current) for tile in pool}
        candidate_scores = {tile: predictive_score(tile, sample) for tile in pool}

        for horizon, weight in HORIZONS:
            target = tile_for(sample.x + sample.vx * horizon, sample.z + sample.vz * horizon)
            if target == current or target not in pool:
                continue
            brank = expected_rank(target, pool, baseline_scores)
            crank = expected_rank(target, pool, candidate_scores)
            weighted_baseline += brank * weight
            weighted_candidate += crank * weight
            total_weight += weight
            observations += 1
            if brank <= 4.0:
                baseline_top4_weight += weight
            if crank <= 4.0:
                candidate_top4_weight += weight
            details.append({
                "sample": sample.name,
                "horizon_s": horizon,
                "target": [target[0], target[1]],
                "baseline_expected_rank": brank,
                "candidate_expected_rank": crank,
                "weight": weight,
            })

    if total_weight <= 0.0:
        raise RuntimeError("frozen trace produced no cross-tile observations")

    baseline_rank = weighted_baseline / total_weight
    candidate_rank = weighted_candidate / total_weight
    rank_improvement = (baseline_rank - candidate_rank) / baseline_rank
    baseline_top4 = baseline_top4_weight / total_weight
    candidate_top4 = candidate_top4_weight / total_weight

    # Frozen promotion gates. These are intentionally stronger than merely
    # beating baseline, so a tiny or trace-specific win cannot pass.
    passed = (
        observations >= 40
        and rank_improvement >= 0.50
        and candidate_rank <= 1.25
        and candidate_top4 >= 0.99
        and candidate_top4 >= baseline_top4
    )

    return {
        "schema_version": 1,
        "tile_size_m": TILE_SIZE,
        "radius": RADIUS,
        "observations": observations,
        "baseline_expected_rank": baseline_rank,
        "candidate_expected_rank": candidate_rank,
        "rank_improvement": rank_improvement,
        "baseline_top4_hit_rate": baseline_top4,
        "candidate_top4_hit_rate": candidate_top4,
        "passed": passed,
        "details": details,
    }


def main() -> int:
    report = evaluate()
    build_dir = Path(__file__).resolve().parents[1] / "build"
    build_dir.mkdir(parents=True, exist_ok=True)
    (build_dir / "rdx-stream-priority-eval.json").write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(
        "YARDMAN_RDX_STREAM_PRIORITY "
        f"baseline_rank={report['baseline_expected_rank']:.4f} "
        f"candidate_rank={report['candidate_expected_rank']:.4f} "
        f"improvement={report['rank_improvement']:.4f} "
        f"top4={report['candidate_top4_hit_rate']:.4f} "
        f"observations={report['observations']} "
        f"result={'PASS' if report['passed'] else 'FAIL'}"
    )
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
