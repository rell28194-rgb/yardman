#!/usr/bin/env python3
"""Semantic mutation gate for Yardman's promoted streaming-priority stack.

Every mutant is curated to remain syntax-valid and represent a realistic
priority or coordinator regression. A mutant only counts as killed when the
unchanged Godot oracle detects it. Parser-breaking mutants are rejected rather
than credited.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

PRIORITY = "streaming_priority.gd"
RUNTIME = "stream_priority_runtime.gd"
PARSE_MARKERS = ("SCRIPT ERROR", "Parse Error", "Parser Error")

ORACLES = {
    "priority": ("res://tests/streaming_priority_test.gd", "YARDMAN_STREAMING_PRIORITY_TEST PASS"),
    "runtime": ("res://tests/stream_priority_runtime_test.gd", "YARDMAN_STREAM_PRIORITY_RUNTIME_TEST PASS"),
}

MUTANTS = [
    {
        "file": PRIORITY,
        "name": "occupied_cell_zero_priority_removed",
        "target": "    if cell == containing_cell(target_world, cell_size):\n        return 0.0",
        "replacement": "    if false:\n        return 0.0",
        "oracles": ["priority", "runtime"],
    },
    {
        "file": PRIORITY,
        "name": "footprint_distance_replaced_by_center_distance",
        "target": "var current_distance := cell_distance(cell, target_world, cell_size)",
        "replacement": "var current_distance := cell_center(cell, cell_size).distance_to(target_world)",
        "oracles": ["priority"],
    },
    {
        "file": PRIORITY,
        "name": "motion_disabled_by_stop_threshold",
        "target": "const STOP_SPEED_MPS := 0.35",
        "replacement": "const STOP_SPEED_MPS := 1000.0",
        "oracles": ["priority", "runtime"],
    },
    {
        "file": PRIORITY,
        "name": "motion_weight_zeroed",
        "target": "const MAX_MOTION_WEIGHT := 0.72",
        "replacement": "const MAX_MOTION_WEIGHT := 0.0",
        "oracles": ["priority", "runtime"],
    },
    {
        "file": PRIORITY,
        "name": "prediction_direction_reversed",
        "target": "var predicted := target_world + velocity_world / speed * lead_distance",
        "replacement": "var predicted := target_world - velocity_world / speed * lead_distance",
        "oracles": ["priority", "runtime"],
    },
    {
        "file": PRIORITY,
        "name": "prediction_lead_zeroed",
        "target": "var lead_distance := minf(speed * horizon, cell_size * 0.85)",
        "replacement": "var lead_distance := minf(speed * horizon, cell_size * 0.0)",
        "oracles": ["priority", "runtime"],
    },
    {
        "file": PRIORITY,
        "name": "score_order_reversed",
        "target": "return score_a < score_b",
        "replacement": "return score_a > score_b",
        "oracles": ["priority", "runtime"],
    },
    {
        "file": PRIORITY,
        "name": "deterministic_x_tie_reversed",
        "target": "return a.x < b.x",
        "replacement": "return a.x > b.x",
        "oracles": ["priority"],
    },
    {
        "file": PRIORITY,
        "name": "containing_cell_rounds_up",
        "target": "return Vector2i(floori(point.x / cell_size), floori(point.y / cell_size))",
        "replacement": "return Vector2i(ceili(point.x / cell_size), ceili(point.y / cell_size))",
        "oracles": ["priority", "runtime"],
    },
    {
        "file": RUNTIME,
        "name": "queue_key_axes_swapped",
        "target": "return Vector2i(int(parts[0]), int(parts[1]))",
        "replacement": "return Vector2i(int(parts[1]), int(parts[0]))",
        "oracles": ["runtime"],
    },
    {
        "file": RUNTIME,
        "name": "two_item_queue_not_sorted",
        "target": "if queue.size() < 2:",
        "replacement": "if queue.size() < 3:",
        "oracles": ["runtime"],
    },
    {
        "file": RUNTIME,
        "name": "world_coordinate_axes_swapped",
        "target": "var target_world := Vector2(float(world[0]), float(world[2]))",
        "replacement": "var target_world := Vector2(float(world[2]), float(world[0]))",
        "oracles": ["runtime"],
    },
    {
        "file": RUNTIME,
        "name": "building_uses_road_tile_size",
        "target": "    if label == \"buildings\":\n        cell_size = float(streamer.get(\"cell_size\"))\n    else:\n        cell_size = float(streamer.get(\"tile_size\"))",
        "replacement": "    if label == \"buildings\":\n        cell_size = float(streamer.get(\"tile_size\"))\n    else:\n        cell_size = float(streamer.get(\"tile_size\"))",
        "oracles": ["runtime"],
    },
    {
        "file": RUNTIME,
        "name": "target_velocity_discarded",
        "target": "var velocity_world := Priority.target_velocity(target)",
        "replacement": "var velocity_world := Vector2.ZERO",
        "oracles": ["runtime"],
    },
    {
        "file": RUNTIME,
        "name": "sort_comparator_arguments_reversed",
        "target": "return Priority.less(_key_cell(str(a)), _key_cell(str(b)), target_world, velocity_world, cell_size)",
        "replacement": "return Priority.less(_key_cell(str(b)), _key_cell(str(a)), target_world, velocity_world, cell_size)",
        "oracles": ["runtime"],
    },
    {
        "file": RUNTIME,
        "name": "valid_world_vector_rejected",
        "target": "if world.size() < 3:",
        "replacement": "if world.size() < 4:",
        "oracles": ["runtime"],
    },
]


def run_oracle(binary: str, godot_dir: Path, oracle: str, timeout: int) -> tuple[int, str]:
    script, marker = ORACLES[oracle]
    proc = subprocess.run(
        [binary, "--headless", "--path", str(godot_dir), "--script", script],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=timeout,
        check=False,
    )
    output = proc.stdout
    passed = proc.returncode == 0 and marker in output and not any(m in output for m in PARSE_MARKERS)
    return (0 if passed else 1), output


def mutate(source: str, mutant: dict[str, object]) -> str:
    target = str(mutant["target"])
    count = source.count(target)
    if count != 1:
        raise RuntimeError(f"{mutant['name']}: expected one target occurrence, found {count}")
    return source.replace(target, str(mutant["replacement"]), 1)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot-binary", default="godot")
    parser.add_argument("--threshold", type=float, default=1.0)
    parser.add_argument("--timeout", type=int, default=30)
    args = parser.parse_args()

    godot_dir = Path(__file__).resolve().parents[1]
    script_dir = godot_dir / "scripts"
    paths = {PRIORITY: script_dir / PRIORITY, RUNTIME: script_dir / RUNTIME}
    originals = {name: path.read_text(encoding="utf-8") for name, path in paths.items()}

    for oracle in ORACLES:
        code, output = run_oracle(args.godot_binary, godot_dir, oracle, args.timeout)
        if code != 0:
            print(f"STREAM_PRIORITY_MUTATION baseline oracle failed: {oracle}", file=sys.stderr)
            print(output[-3000:], file=sys.stderr)
            return 2

    results: list[dict[str, object]] = []
    try:
        for mutant in MUTANTS:
            filename = str(mutant["file"])
            path = paths[filename]
            path.write_text(mutate(originals[filename], mutant), encoding="utf-8")
            killed = False
            parse_dirty = False
            tails: list[str] = []
            for oracle in mutant["oracles"]:
                code, output = run_oracle(args.godot_binary, godot_dir, str(oracle), args.timeout)
                parse_dirty = parse_dirty or any(marker in output for marker in PARSE_MARKERS)
                tails.append(output[-800:])
                if code != 0:
                    killed = True
                    break
            results.append({
                "file": filename,
                "name": mutant["name"],
                "killed": killed,
                "parse_dirty": parse_dirty,
                "tail": "\n---\n".join(tails),
            })
            print(f"STREAM_PRIORITY_MUTATION {'KILLED' if killed else 'SURVIVED'} {filename}:{mutant['name']} parse_dirty={int(parse_dirty)}")
            path.write_text(originals[filename], encoding="utf-8")
    finally:
        for filename, path in paths.items():
            path.write_text(originals[filename], encoding="utf-8")

    invalid = [r for r in results if r["parse_dirty"]]
    valid = [r for r in results if not r["parse_dirty"]]
    killed = [r for r in valid if r["killed"]]
    survivors = [r for r in valid if not r["killed"]]
    score = len(killed) / len(valid) if valid else 0.0

    report = {
        "schema_version": 1,
        "mutants_total": len(results),
        "mutants_valid": len(valid),
        "mutants_invalid": len(invalid),
        "mutants_killed": len(killed),
        "mutants_survived": len(survivors),
        "mutation_score": score,
        "required_score": args.threshold,
        "survivors": [f"{r['file']}:{r['name']}" for r in survivors],
        "invalid": [f"{r['file']}:{r['name']}" for r in invalid],
        "results": results,
    }
    build = godot_dir / "build"
    build.mkdir(parents=True, exist_ok=True)
    (build / "stream-priority-mutation.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print(
        "YARDMAN_STREAM_PRIORITY_MUTATION_SCORE "
        f"score={score:.4f} killed={len(killed)} valid={len(valid)} "
        f"survivors={len(survivors)} invalid={len(invalid)} threshold={args.threshold:.4f}"
    )
    if invalid:
        return 3
    if survivors or score < args.threshold:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
