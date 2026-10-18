#!/usr/bin/env python3
"""Frozen immediate-I/O evaluator for Yardman road/terrain stream priority.

This is intentionally independent from the Godot implementation. It measures
only the next few seconds because national Jamaica traces showed that longer
straight-line prediction over-steers on curving roads. Residency/candidate sets
remain identical; only queue order is scored.
"""

from __future__ import annotations

import json
import math
from dataclasses import dataclass
from pathlib import Path

TILE_SIZE = 4096.0
RADIUS = 2
PREDICTION_HORIZON_S = 2.0
PREDICTION_WEIGHT = 0.20
TARGET_HORIZONS = ((0.5, 1.0), (1.0, 2.0), (2.0, 5.0), (3.0, 3.0), (5.0, 1.0))

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
    return (
        distance2_to_aabb(s.x, s.z, tile)
        + PREDICTION_WEIGHT * distance2_to_aabb(
            s.x + s.vx * PREDICTION_HORIZON_S,
            s.z + s.vz * PREDICTION_HORIZON_S,
            tile,
        )
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
    candidate_top4_weight = 0.0
    observations = 0

    for sample in SAMPLES:
        current = tile_for(sample.x, sample.z)
        pool = candidates(current)
        baseline_scores = {tile: baseline_score(tile, current) for tile in pool}
        candidate_scores = {tile: predictive_score(tile, sample) for tile in pool}

        for horizon, weight in TARGET_HORIZONS:
            target = tile_for(sample.x + sample.vx * horizon, sample.z + sample.vz * horizon)
            if target == current or target not in pool:
                continue
            brank = expected_rank(target, pool, baseline_scores)
            crank = expected_rank(target, pool, candidate_scores)
            weighted_baseline += brank * weight
            weighted_candidate += crank * weight
            total_weight += weight
            observations += 1
            if crank <= 4.0:
                candidate_top4_weight += weight

    if total_weight <= 0.0:
        raise RuntimeError("frozen trace produced no cross-tile observations")

    baseline_rank = weighted_baseline / total_weight
    candidate_rank = weighted_candidate / total_weight
    rank_improvement = (baseline_rank - candidate_rank) / baseline_rank
    candidate_top4 = candidate_top4_weight / total_weight

    passed = (
        observations >= 20
        and rank_improvement >= 0.50
        and candidate_rank <= 1.60
        and candidate_top4 >= 0.99
    )

    return {
        "schema_version": 2,
        "prediction_horizon_s": PREDICTION_HORIZON_S,
        "prediction_weight": PREDICTION_WEIGHT,
        "observations": observations,
        "baseline_expected_rank": baseline_rank,
        "candidate_expected_rank": candidate_rank,
        "rank_improvement": rank_improvement,
        "candidate_top4_hit_rate": candidate_top4,
        "passed": passed,
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
