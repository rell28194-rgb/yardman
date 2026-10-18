#!/usr/bin/env python3
"""Audit compiled Yardman road vertical profiles without changing production geometry.

Jamaica contains legitimately steep roads. This tool records exact source, edge,
segment, class, and grade evidence instead of enforcing a guessed universal cap.
"""
from __future__ import annotations

import argparse
import heapq
import json
import math
from collections import defaultdict
from pathlib import Path

STRUCTURAL_FLAGS = 2 | 4


def horizontal_distance(a, b) -> float:
    return math.hypot(float(b[0]) - float(a[0]), float(b[2]) - float(a[2]))


def percentile(sorted_values: list[float], fraction: float) -> float:
    if not sorted_values:
        return 0.0
    if len(sorted_values) == 1:
        return sorted_values[0]
    position = (len(sorted_values) - 1) * fraction
    lower = int(math.floor(position))
    upper = int(math.ceil(position))
    if lower == upper:
        return sorted_values[lower]
    weight = position - lower
    return sorted_values[lower] * (1.0 - weight) + sorted_values[upper] * weight


def _bounded_top(heap: list, score: float, tie: str, record: dict, top_n: int) -> None:
    item = (float(score), tie, record)
    if len(heap) < top_n:
        heapq.heappush(heap, item)
    elif item[:2] > heap[0][:2]:
        heapq.heapreplace(heap, item)


def _grade_record(edge_id: str, edge: dict, segment_index: int, segment_count: int,
                  a, b, signed_grade: float, run_m: float) -> dict:
    return {
        "edge_id": str(edge_id),
        "source_way": str(edge.get("source_way", "")),
        "class": str(edge.get("class", "unknown")),
        "segment_index": int(segment_index),
        "edge_segment_count": int(segment_count),
        "touches_graph_endpoint": segment_index == 0 or segment_index == segment_count - 1,
        "run_m": round(run_m, 3),
        "signed_grade_pct": round(signed_grade, 4),
        "abs_grade_pct": round(abs(signed_grade), 4),
        "from": [round(float(a[0]), 3), round(float(a[1]), 3), round(float(a[2]), 3)],
        "to": [round(float(b[0]), 3), round(float(b[1]), 3), round(float(b[2]), 3)],
    }


def _break_record(edge_id: str, edge: dict, vertex_index: int, path,
                  incoming: float, outgoing: float) -> dict:
    point = path[vertex_index]
    return {
        "edge_id": str(edge_id),
        "source_way": str(edge.get("source_way", "")),
        "class": str(edge.get("class", "unknown")),
        "vertex_index": int(vertex_index),
        "incoming_grade_pct": round(incoming, 4),
        "outgoing_grade_pct": round(outgoing, 4),
        "grade_break_pct_points": round(abs(outgoing - incoming), 4),
        "position": [round(float(point[0]), 3), round(float(point[1]), 3), round(float(point[2]), 3)],
    }


def _distribution_summary(values: list[float]) -> dict:
    ordered = sorted(values)
    return {
        "segments": len(ordered),
        "grade_p95_pct": round(percentile(ordered, 0.95), 4),
        "grade_p99_pct": round(percentile(ordered, 0.99), 4),
        "grade_max_pct": round(max(ordered, default=0.0), 4),
        "grade_over_20pct_segments": sum(value > 20.0 for value in ordered),
        "grade_over_30pct_segments": sum(value > 30.0 for value in ordered),
    }


def audit_road_profiles(roads_root: Path, *, top_n: int = 50) -> dict:
    if top_n < 1:
        raise ValueError("top_n must be positive")
    graph_root = roads_root / "graph"
    shards = sorted(graph_root.glob("edges_*.json"))
    if not shards:
        raise ValueError(f"No road edge shards found under {graph_root}")

    class_grades: dict[str, list[float]] = defaultdict(list)
    all_grades: list[float] = []
    all_breaks: list[float] = []
    top_grade_heap: list = []
    top_break_heap: list = []
    edge_count = 0
    structural_edges_skipped = 0

    for shard in shards:
        payload = json.loads(shard.read_text(encoding="utf-8"))
        if not isinstance(payload, dict):
            raise ValueError(f"Road edge shard is not an object: {shard}")
        for edge_id in sorted(payload):
            edge = payload[edge_id]
            edge_count += 1
            if int(edge.get("flags", 0)) & STRUCTURAL_FLAGS:
                structural_edges_skipped += 1
                continue
            path = edge.get("path") or []
            segment_total = max(0, len(path) - 1)
            signed_grades: list[float | None] = []
            for segment_index, (a, b) in enumerate(zip(path, path[1:])):
                run = horizontal_distance(a, b)
                if run < 0.25 or not math.isfinite(run):
                    signed_grades.append(None)
                    continue
                signed_grade = ((float(b[1]) - float(a[1])) / run) * 100.0
                if not math.isfinite(signed_grade):
                    raise ValueError(f"Non-finite grade at {edge_id}:{segment_index}")
                absolute = abs(signed_grade)
                class_name = str(edge.get("class", "unknown"))
                class_grades[class_name].append(absolute)
                all_grades.append(absolute)
                record = _grade_record(edge_id, edge, segment_index, segment_total, a, b, signed_grade, run)
                _bounded_top(top_grade_heap, absolute, f"{edge_id}:{segment_index:08d}", record, top_n)
                signed_grades.append(signed_grade)

            for vertex_index in range(1, len(path) - 1):
                incoming = signed_grades[vertex_index - 1] if vertex_index - 1 < len(signed_grades) else None
                outgoing = signed_grades[vertex_index] if vertex_index < len(signed_grades) else None
                if incoming is None or outgoing is None:
                    continue
                grade_break = abs(outgoing - incoming)
                all_breaks.append(grade_break)
                record = _break_record(edge_id, edge, vertex_index, path, incoming, outgoing)
                _bounded_top(top_break_heap, grade_break, f"{edge_id}:{vertex_index:08d}", record, top_n)

    ordered_all = sorted(all_grades)
    ordered_breaks = sorted(all_breaks)
    top_grades = [item[2] for item in top_grade_heap]
    top_breaks = [item[2] for item in top_break_heap]
    top_grades.sort(key=lambda row: (-row["abs_grade_pct"], row["edge_id"], row["segment_index"]))
    top_breaks.sort(key=lambda row: (-row["grade_break_pct_points"], row["edge_id"], row["vertex_index"]))

    endpoint_outliers = sum(1 for row in top_grades if row["touches_graph_endpoint"])
    return {
        "format": 1,
        "purpose": "source-level evidence for road vertical-profile review; no geometry is changed",
        "stats": {
            "edge_shards": len(shards),
            "edges": edge_count,
            "structural_edges_skipped": structural_edges_skipped,
            "grade_segments": len(ordered_all),
            "grade_break_vertices": len(ordered_breaks),
            "grade_p95_pct": round(percentile(ordered_all, 0.95), 4),
            "grade_p99_pct": round(percentile(ordered_all, 0.99), 4),
            "grade_max_pct": round(max(ordered_all, default=0.0), 4),
            "grade_over_20pct_segments": sum(value > 20.0 for value in ordered_all),
            "grade_over_30pct_segments": sum(value > 30.0 for value in ordered_all),
            "grade_break_p95_pct_points": round(percentile(ordered_breaks, 0.95), 4),
            "grade_break_p99_pct_points": round(percentile(ordered_breaks, 0.99), 4),
            "grade_break_max_pct_points": round(max(ordered_breaks, default=0.0), 4),
            "top_grade_segments_touching_graph_endpoint": endpoint_outliers,
        },
        "by_highway_class": {
            name: _distribution_summary(class_grades[name]) for name in sorted(class_grades)
        },
        "top_grade_segments": top_grades,
        "top_grade_breaks": top_breaks,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("roads_root", type=Path, help="Compiled roads root containing graph/edges_*.json")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--top", type=int, default=50)
    args = parser.parse_args()
    report = audit_road_profiles(args.roads_root, top_n=args.top)
    text = json.dumps(report, indent=2, sort_keys=True)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text + "\n", encoding="utf-8")
    print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
