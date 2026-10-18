#!/usr/bin/env python3
"""Mutation-grade the predictive stream priority policy against independent Godot oracles."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

MUTANTS = [
    ("drop_near_prediction", 'const WEIGHT_NEAR := 0.60', 'const WEIGHT_NEAR := 0.0'),
    ("drop_far_prediction", 'const WEIGHT_FAR := 0.30', 'const WEIGHT_FAR := 0.0'),
    ("drop_current_distance", 'const WEIGHT_NOW := 1.0', 'const WEIGHT_NOW := 0.0'),
    ("near_horizon_zero", 'const HORIZON_NEAR_S := 10.0', 'const HORIZON_NEAR_S := 0.0'),
    ("far_horizon_near", 'const HORIZON_FAR_S := 30.0', 'const HORIZON_FAR_S := 10.0'),
    ("disable_speed_clamp", 'if speed <= MAX_PREDICTION_SPEED_MPS:\n        return velocity_mps', 'if true:\n        return velocity_mps'),
    ("low_speed_clamp", 'const MAX_PREDICTION_SPEED_MPS := 120.0', 'const MAX_PREDICTION_SPEED_MPS := 20.0'),
    ("predict_backward_near", 'var predicted_near := world_xz + velocity * HORIZON_NEAR_S', 'var predicted_near := world_xz - velocity * HORIZON_NEAR_S'),
    ("predict_backward_far", 'var predicted_far := world_xz + velocity * HORIZON_FAR_S', 'var predicted_far := world_xz - velocity * HORIZON_FAR_S'),
    ("invalid_tile_open", 'if tile_size <= 0.0:\n        return INF', 'if tile_size < 0.0:\n        return INF'),
    ("east_aabb_sign", 'dx = min_x - world_xz.x', 'dx = world_xz.x - min_x'),
    ("west_aabb_sign", 'dx = world_xz.x - max_x', 'dx = max_x - world_xz.x'),
    ("tie_break_reverse_y", 'return a.y < b.y', 'return a.y > b.y'),
    ("tie_break_reverse_x", 'return a.x < b.x', 'return a.x > b.x'),
]


def run_test(godot: str, root: Path, script: str, timeout: int) -> tuple[int, str]:
    proc = subprocess.run(
        [godot, "--headless", "--path", str(root), "--script", script],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=timeout,
        check=False,
    )
    return proc.returncode, proc.stdout


def oracle_passes(godot: str, root: Path, timeout: int) -> tuple[bool, str]:
    outputs: list[str] = []
    for script, marker in [
        ("res://tests/stream_priority_policy_test.gd", "YARDMAN_STREAM_PRIORITY_POLICY_TEST PASS"),
        ("res://tests/stream_priority_integration_test.gd", "YARDMAN_STREAM_PRIORITY_INTEGRATION_TEST PASS"),
    ]:
        code, output = run_test(godot, root, script, timeout)
        outputs.append(output)
        if code != 0 or marker not in output:
            return False, "\n".join(outputs)
    return True, "\n".join(outputs)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot-binary", default="godot")
    parser.add_argument("--threshold", type=float, default=0.90)
    parser.add_argument("--timeout", type=int, default=30)
    args = parser.parse_args()

    godot_root = Path(__file__).resolve().parents[1]
    policy = godot_root / "scripts" / "stream_priority_policy.gd"
    original = policy.read_text(encoding="utf-8")

    baseline_ok, baseline_output = oracle_passes(args.godot_binary, godot_root, args.timeout)
    if not baseline_ok:
        print("BASELINE_FAILED")
        print(baseline_output)
        return 2

    killed = 0
    survived = 0
    invalid = 0
    survivor_names: list[str] = []
    invalid_names: list[str] = []
    try:
        for name, needle, replacement in MUTANTS:
            if needle not in original:
                print(f"MUTANT_INVALID name={name} reason=needle_missing")
                invalid += 1
                invalid_names.append(name)
                continue
            mutated = original.replace(needle, replacement, 1)
            policy.write_text(mutated, encoding="utf-8")
            passed, output = oracle_passes(args.godot_binary, godot_root, args.timeout)
            parse_invalid = "Parse Error" in output or "Could not parse" in output
            if parse_invalid:
                invalid += 1
                invalid_names.append(name)
                print(f"MUTANT_INVALID name={name} reason=parse")
            elif passed:
                survived += 1
                survivor_names.append(name)
                print(f"MUTANT_SURVIVED name={name}")
            else:
                killed += 1
                print(f"MUTANT_KILLED name={name}")
    finally:
        policy.write_text(original, encoding="utf-8")

    valid = killed + survived
    score = float(killed) / float(valid) if valid else 0.0
    print(
        "YARDMAN_RDX_STREAM_PRIORITY_MUTATION "
        f"score={score:.4f} killed={killed} valid={valid} survivors={survived} "
        f"invalid={invalid} threshold={args.threshold:.4f}"
    )
    if survivor_names:
        print("SURVIVORS " + ",".join(survivor_names))
    if invalid_names:
        print("INVALID " + ",".join(invalid_names))
    return 0 if valid > 0 and score >= args.threshold else 1


if __name__ == "__main__":
    raise SystemExit(main())
