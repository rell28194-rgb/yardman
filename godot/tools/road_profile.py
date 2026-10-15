"""Deterministic longitudinal road-profile refinement for Yardman's Jamaica graph.

The DEM remains vertical authority. This pass only removes sub-metre high-frequency
bumps from interior road vertices while preserving every graph-edge endpoint and
shared OSM junction elevation. Bridge/tunnel profiles remain structural authority
and are never modified here.
"""
from __future__ import annotations

import math


STRUCTURAL_FLAGS = 2 | 4


def _horizontal_distance(a, b) -> float:
    return math.hypot(float(b[0]) - float(a[0]), float(b[2]) - float(a[2]))


def _edge_length(path) -> float:
    return sum(math.dist(a, b) for a, b in zip(path, path[1:]))


def _smoothed_path(path, max_adjustment_m: float, passes: int, blend: float):
    original = [tuple(point) for point in path]
    if len(original) < 3:
        return original, []
    values = [float(point[1]) for point in original]
    original_y = list(values)
    for _ in range(passes):
        previous = list(values)
        for index in range(1, len(original) - 1):
            left = _horizontal_distance(original[index - 1], original[index])
            right = _horizontal_distance(original[index], original[index + 1])
            if left < 0.25 or right < 0.25 or not math.isfinite(left + right):
                continue
            # Elevation of a straight grade between neighbouring stations at the
            # current station. Unequal OSM node spacing therefore cannot bias it.
            target = (previous[index - 1] * right + previous[index + 1] * left) / (left + right)
            candidate = previous[index] + (target - previous[index]) * blend
            lo = original_y[index] - max_adjustment_m
            hi = original_y[index] + max_adjustment_m
            values[index] = min(hi, max(lo, candidate))
    refined = []
    adjustments = []
    for index, point in enumerate(original):
        y = original_y[index] if index in (0, len(original) - 1) else values[index]
        if not math.isfinite(y):
            raise ValueError("Road profile produced non-finite elevation")
        refined.append((float(point[0]), round(y, 6), float(point[2])))
        adjustments.append(y - original_y[index])
    return refined, adjustments


def _percentile(sorted_values: list[float], fraction: float) -> float:
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


def _grade_diagnostics(edges: dict) -> dict:
    """Measure grades and vertical grade breaks without silently rewriting them.

    Jamaica has genuinely steep mountain roads, so this is an evidence gate rather
    than a blanket grade clamp. Extreme grades and abrupt changes of grade are
    surfaced with exact edge/segment locators for source/DEM inspection. True
    positive-to-negative and negative-to-positive reversals are counted separately
    as crest and sag candidates for the road-engineering pass.
    """
    grades: list[float] = []
    grade_breaks: list[float] = []
    worst_edge = ""
    worst_segment = -1
    worst_grade = -1.0
    worst_break_edge = ""
    worst_break_vertex = -1
    worst_break = -1.0
    crest_vertices = 0
    sag_vertices = 0
    for edge_id in sorted(edges):
        edge = edges[edge_id]
        if int(edge.get("flags", 0)) & STRUCTURAL_FLAGS:
            continue
        path = edge.get("path") or []
        signed_grades: list[float | None] = []
        for segment_index, (a, b) in enumerate(zip(path, path[1:])):
            run = _horizontal_distance(a, b)
            if run < 0.25 or not math.isfinite(run):
                signed_grades.append(None)
                continue
            rise = float(b[1]) - float(a[1])
            signed_grade = (rise / run) * 100.0
            if not math.isfinite(signed_grade):
                raise ValueError(f"Non-finite road grade at {edge_id}:{segment_index}")
            signed_grades.append(signed_grade)
            grade = abs(signed_grade)
            grades.append(grade)
            if grade > worst_grade:
                worst_grade = grade
                worst_edge = str(edge_id)
                worst_segment = segment_index
        for vertex_index in range(1, len(path) - 1):
            previous = signed_grades[vertex_index - 1] if vertex_index - 1 < len(signed_grades) else None
            following = signed_grades[vertex_index] if vertex_index < len(signed_grades) else None
            if previous is None or following is None:
                continue
            grade_break = abs(following - previous)
            grade_breaks.append(grade_break)
            if grade_break > worst_break:
                worst_break = grade_break
                worst_break_edge = str(edge_id)
                worst_break_vertex = vertex_index
            if previous > 0.0 and following < 0.0:
                crest_vertices += 1
            elif previous < 0.0 and following > 0.0:
                sag_vertices += 1
    ordered = sorted(grades)
    ordered_breaks = sorted(grade_breaks)
    return {
        "profile_grade_segments": len(ordered),
        "profile_grade_max_pct": round(max(ordered, default=0.0), 4),
        "profile_grade_p95_pct": round(_percentile(ordered, 0.95), 4),
        "profile_grade_p99_pct": round(_percentile(ordered, 0.99), 4),
        "profile_grade_over_20pct_segments": sum(value > 20.0 for value in ordered),
        "profile_grade_over_30pct_segments": sum(value > 30.0 for value in ordered),
        "profile_grade_worst_edge": worst_edge,
        "profile_grade_worst_segment": worst_segment,
        "profile_grade_break_vertices": len(ordered_breaks),
        "profile_grade_break_max_pct_points": round(max(ordered_breaks, default=0.0), 4),
        "profile_grade_break_p95_pct_points": round(_percentile(ordered_breaks, 0.95), 4),
        "profile_grade_break_over_10pp_vertices": sum(value > 10.0 for value in ordered_breaks),
        "profile_grade_break_over_20pp_vertices": sum(value > 20.0 for value in ordered_breaks),
        "profile_grade_break_worst_edge": worst_break_edge,
        "profile_grade_break_worst_vertex": worst_break_vertex,
        "profile_crest_reversal_vertices": crest_vertices,
        "profile_sag_reversal_vertices": sag_vertices,
    }


def smooth_network_profiles(network: dict, *, max_adjustment_m: float = 0.45,
                            passes: int = 2, blend: float = 0.55) -> dict:
    """Refine interior edge elevations and propagate them to streamed surfaces.

    ``network`` is the object returned by ``road_graph.build_network``. Graph-edge
    endpoints are invariant, so independently smoothed edges still meet exactly at
    OSM junctions. Surface polygon Y values intentionally stay as sampled terrain;
    the runtime earthworks system uses that difference to construct cut/fill ties.
    """
    if not math.isfinite(max_adjustment_m) or max_adjustment_m < 0.0:
        raise ValueError("max_adjustment_m must be finite and non-negative")
    if passes < 0:
        raise ValueError("passes must be non-negative")
    if not math.isfinite(blend) or not 0.0 <= blend <= 1.0:
        raise ValueError("blend must be finite and within 0..1")

    edges = network.get("edges", {})
    refined_by_edge = {}
    all_adjustments = []
    smoothed_vertices = 0
    structural_edges_skipped = 0
    edge_lengths_updated = 0
    for edge_id in sorted(edges):
        edge = edges[edge_id]
        path = edge.get("path") or []
        if int(edge.get("flags", 0)) & STRUCTURAL_FLAGS:
            structural_edges_skipped += 1
            continue
        refined, adjustments = _smoothed_path(path, max_adjustment_m, passes, blend)
        if not adjustments:
            continue
        edge["path"] = refined
        edge["length_m"] = round(_edge_length(refined), 3)
        edge_lengths_updated += 1
        refined_by_edge[edge_id] = refined
        changed = [value for index, value in enumerate(adjustments)
                   if index not in (0, len(adjustments) - 1) and abs(value) > 1e-9]
        smoothed_vertices += len(changed)
        all_adjustments.extend(changed)
        edge["elevation_profile"] = "DEM + bounded longitudinal smoothing; endpoints preserved"

    # Surface records store the graph edge id and path-local segment index.
    # Update only deck centreline Y. Polygon Y remains raw terrain evidence.
    updated_surface_records = 0
    for segments in network.get("tiles", {}).values():
        for segment in segments:
            if not isinstance(segment, list) or len(segment) < 12:
                continue
            edge_id = str(segment[7])
            path = refined_by_edge.get(edge_id)
            if not path:
                continue
            segment_index = int(segment[8])
            if segment_index < 0 or segment_index + 1 >= len(path):
                raise ValueError(f"Road surface segment index escaped edge path: {edge_id}:{segment_index}")
            segment[9] = path[segment_index][1]
            segment[10] = path[segment_index + 1][1]
            updated_surface_records += 1

    # Parish QA/spawn anchors were selected from exact path vertices. Preserve X/Z
    # and move only Y when that chosen vertex was one of the refined interiors.
    updated_anchors = 0
    for anchor in network.get("anchor_roads", {}).values():
        edge_id = str(anchor.get("road_edge_id", ""))
        path = refined_by_edge.get(edge_id)
        road_position = anchor.get("road_position")
        if not path or not road_position or len(road_position) < 3:
            continue
        x, z = float(road_position[0]), float(road_position[2])
        match = min(path, key=lambda point: math.hypot(float(point[0]) - x, float(point[2]) - z))
        if math.hypot(float(match[0]) - x, float(match[2]) - z) <= 0.002:
            anchor["road_position"] = (x, float(match[1]), z)
            updated_anchors += 1

    absolute = [abs(value) for value in all_adjustments]
    stats = {
        "profile_smoothed_vertices": smoothed_vertices,
        "profile_surface_records_updated": updated_surface_records,
        "profile_anchors_updated": updated_anchors,
        "profile_structural_edges_skipped": structural_edges_skipped,
        "profile_edge_lengths_updated": edge_lengths_updated,
        "profile_max_adjustment_m": round(max(absolute, default=0.0), 6),
        "profile_mean_adjustment_m": round(sum(absolute) / len(absolute), 6) if absolute else 0.0,
        "profile_adjustment_limit_m": max_adjustment_m,
        "profile_passes": passes,
    }
    stats.update(_grade_diagnostics(edges))
    network.setdefault("stats", {}).update(stats)
    return stats