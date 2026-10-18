#!/usr/bin/env python3
"""Mutation-grade the short-horizon predictive stream priority policy."""

from __future__ import annotations

import argparse
import subprocess
from pathlib import Path

MUTANTS = [
    ("drop_prediction", 'const WEIGHT_PREDICTED := 0.20', 'const WEIGHT_PREDICTED := 0.0'),
    ("drop_current_distance", 'const WEIGHT_NOW := 1.0', 'const WEIGHT_NOW := 0.0'),
    ("zero_horizon", 'const PREDICTION_HORIZON_S := 2.0', 'const PREDICTION_HORIZON_S := 0.0'),
    ("long_horizon", 'const PREDICTION_HORIZON_S := 2.0', 'const PREDICTION_HORIZON_S := 10.0'),
    ("reverse_prediction", 'var predicted := world_xz + velocity * PREDICTION_HORIZON_S', 'var predicted := world_xz - velocity * PREDICTION_HORIZON_S'),
    ("disable_speed_clamp", 'if speed <= MAX_PREDICTION_SPEED_MPS:\n        return velocity_mps', 'if true:\n        return velocity_mps'),
    ("low_speed_clamp", 'const MAX_PREDICTION_SPEED_MPS := 120.0', 'const MAX_PREDICTION_SPEED_MPS := 20.0'),
    ("invalid_tile_open", 'if tile_size <= 0.0:\n        return INF', 'if tile_size < 0.0:\n        return INF'),
    ("lose_west_distance", 'dx = min_x - world_xz.x', 'dx = 0.0'),
    ("lose_east_distance", 'dx = world_xz.x - max_x', 'dx = 0.0'),
    ("lose_north_distance", 'dz = min_z - world_xz.y', 'dz = 0.0'),
    ("lose_south_distance", 'dz = world_xz.y - max_z', 'dz = 0.0'),
    ("tie_break_reverse_y", 'return a.y < b.y', 'return a.y > b.y'),
    ("tie_break_reverse_x", 'return a.x < b.x', 'return a.x > b.x'),
    ("allow_negative_elapsed", 'if elapsed_seconds <= 0.000001 or not is_finite(elapsed_seconds):', 'if elapsed_seconds == 0.0 or not is_finite(elapsed_seconds):'),
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

    killed = survived = invalid = 0
    survivors: list[str] = []
    invalid_names: list[str] = []
    try:
        for name, needle, replacement in MUTANTS:
            if needle not in original:
                invalid += 1
                invalid_names.append(name)
                print(f"MUTANT_INVALID name={name} reason=needle_missing")
                continue
            policy.write_text(original.replace(needle, replacement, 1), encoding="utf-8")
            passed, output = oracle_passes(args.godot_binary, godot_root, args.timeout)
            if "Parse Error" in output or "Could not parse" in output:
                invalid += 1
                invalid_names.append(name)
                print(f"MUTANT_INVALID name={name} reason=parse")
            elif passed:
                survived += 1
                survivors.append(name)
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
    if survivors:
        print("SURVIVORS " + ",".join(survivors))
    if invalid_names:
        print("INVALID " + ",".join(invalid_names))
    return 0 if valid > 0 and score >= args.threshold else 1


if __name__ == "__main__":
    raise SystemExit(main())
