#!/usr/bin/env python3
"""Semantic mutation gate for RDX-004 cluster policy.

The evaluator remains unchanged. Each mutant is applied to a temporary working
copy of the production-neutral cluster policy, the same Godot oracle is run in a
fresh process, and the source is restored after every case. A mutant is killed
only when the evaluator rejects it with a non-zero exit code.
"""
from __future__ import annotations

import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
POLICY = ROOT / "godot" / "scripts" / "render_cluster_policy.gd"
GODOT = "godot"
BASE_CMD = [
    GODOT,
    "--headless",
    "--path",
    str(ROOT / "godot"),
    "--script",
    "res://tests/cluster_microbench_test.gd",
]

MUTANTS = [
    (
        "shrink_cluster_bounds",
        "const BOUNDS_PAD := 0.0001",
        "const BOUNDS_PAD := -0.25",
    ),
    (
        "corrupt_triangle_index",
        "        reordered.append(indices[first + 2])",
        "        reordered.append(indices[first + 1])",
    ),
    (
        "exceed_triangle_budget",
        "    var max_indices := max_triangles * 3",
        "    var max_indices := (max_triangles + 1) * 3",
    ),
    (
        "offset_cluster_range",
        '        clusters.append({"first_index": first_index, "index_count": index_count, "bounds": bounds})',
        '        clusters.append({"first_index": first_index + 3, "index_count": index_count, "bounds": bounds})',
    ),
    (
        "truncate_cluster_range",
        '        clusters.append({"first_index": first_index, "index_count": index_count, "bounds": bounds})',
        '        clusters.append({"first_index": first_index, "index_count": index_count - 3, "bounds": bounds})',
    ),
    (
        "triangle_bounds_first_index_only",
        "    for offset in range(first_index, first_index + index_count):",
        "    for offset in range(first_index, first_index + 1):",
    ),
    (
        "destroy_triangle_spatial_order",
        "        triangle.code = _morton_2d(_quantize(centroid.x, minimum.x, maximum.x), _quantize(centroid.z, minimum.y, maximum.y))",
        "        triangle.code = _quantize(centroid.y, -100.0, 100.0)",
    ),
    (
        "exceed_point_budget",
        "        var count := mini(max_points, ordered.size() - cursor)",
        "        var count := mini(max_points + 1, ordered.size() - cursor)",
    ),
    (
        "duplicate_point_members",
        "            members.append(int(ordered[cursor + offset].index))",
        "            members.append(int(ordered[cursor].index))",
    ),
    (
        "point_bounds_first_member_only",
        "    for member in members:\n        var point := points[member]",
        "    for member in members.slice(0, 1):\n        var point := points[member]",
    ),
    (
        "destroy_point_spatial_order",
        '            "code": _morton_2d(_quantize(point.x, minimum.x, maximum.x), _quantize(point.z, minimum.y, maximum.y)),',
        '            "code": _quantize(point.y, -100.0, 100.0),',
    ),
    (
        "allow_nonfinite_points",
        "    for point in points:\n        if not point.is_finite():\n            return {\"error\": \"non-finite point\"}",
        "    for point in points:\n        if false and not point.is_finite():\n            return {\"error\": \"non-finite point\"}",
    ),
    (
        "allow_bad_indices",
        "        if index < 0 or index >= vertices.size():",
        "        if false and (index < 0 or index >= vertices.size()):",
    ),
    (
        "allow_malformed_triangle_payload",
        "    if indices.size() % 3 != 0:",
        "    if false and indices.size() % 3 != 0:",
    ),
]


def run_oracle() -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        BASE_CMD,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=45,
        check=False,
    )


def concise_tail(output: str, count: int = 7) -> str:
    lines = [line for line in output.splitlines() if line.strip()]
    return " | ".join(lines[-count:])


def main() -> int:
    original = POLICY.read_text(encoding="utf-8")
    baseline = run_oracle()
    if baseline.returncode != 0 or "YARDMAN_RDX_CLUSTER_MICROBENCH result=PASS" not in baseline.stdout:
        print("YARDMAN_RDX_CLUSTER_MUTATION baseline=FAIL " + concise_tail(baseline.stdout))
        return 2

    killed = 0
    valid = 0
    survivors: list[str] = []
    invalid: list[str] = []
    try:
        for name, old, new in MUTANTS:
            occurrences = original.count(old)
            if occurrences != 1:
                invalid.append(name)
                print(f"YARDMAN_RDX_CLUSTER_MUTANT name={name} result=INVALID occurrences={occurrences}")
                continue
            valid += 1
            POLICY.write_text(original.replace(old, new, 1), encoding="utf-8")
            result = run_oracle()
            if result.returncode != 0 or "result=PASS" not in result.stdout:
                killed += 1
                print(f"YARDMAN_RDX_CLUSTER_MUTANT name={name} result=KILLED tail={concise_tail(result.stdout)}")
            else:
                survivors.append(name)
                print(f"YARDMAN_RDX_CLUSTER_MUTANT name={name} result=SURVIVED")
            POLICY.write_text(original, encoding="utf-8")
    finally:
        POLICY.write_text(original, encoding="utf-8")

    score = float(killed) / float(valid) if valid else 0.0
    print(
        "YARDMAN_RDX_CLUSTER_MUTATION score=%.4f killed=%d valid=%d survivors=%d invalid=%d threshold=0.9000"
        % (score, killed, valid, len(survivors), len(invalid))
    )
    if survivors:
        print("YARDMAN_RDX_CLUSTER_MUTATION_SURVIVORS " + ",".join(survivors))
    if invalid:
        print("YARDMAN_RDX_CLUSTER_MUTATION_INVALID " + ",".join(invalid))
    return 0 if valid > 0 and score >= 0.90 and not survivors and not invalid else 1


if __name__ == "__main__":
    sys.exit(main())
