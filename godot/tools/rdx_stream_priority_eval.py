#!/usr/bin/env python3
"""Frozen-trace evaluator for Yardman streaming queue priority R&D.

This is test-only research evidence. It compares the currently shipped-style
"sort only when the containing cell changes" policy with a candidate that also
re-sorts remaining queued work as position/velocity changes under backlog.
It does not substitute for real Jamaica telemetry or Android device evidence.
"""

from __future__ import annotations

import json
import math
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TRACE_PATH = ROOT / "tests" / "fixtures" / "stream_priority_rdx_traces.json"
PRIORITY_PATH = ROOT / "scripts" / "streaming_priority.gd"
REPORT_PATH = ROOT / "build" / "rdx-stream-priority-eval.json"


def _constant(source: str, name: str) -> float:
    match = re.search(rf"const\s+{re.escape(name)}\s*:=\s*([0-9.]+)", source)
    if not match:
        raise RuntimeError(f"missing streaming-priority constant {name}")
    return float(match.group(1))


def _parameters() -> dict[str, float]:
    source = PRIORITY_PATH.read_text(encoding="utf-8")
    prediction = re.search(r"prediction_seconds:\s*float\s*=\s*([0-9.]+)", source)
    lead_fraction = re.search(r"cell_size\s*\*\s*([0-9.]+)\)", source)
    if not prediction or not lead_fraction:
        raise RuntimeError("could not bind evaluator to streaming_priority.gd")
    return {
        "stop_speed_mps": _constant(source, "STOP_SPEED_MPS"),
        "full_bias_speed_mps": _constant(source, "FULL_BIAS_SPEED_MPS"),
        "max_motion_weight": _constant(source, "MAX_MOTION_WEIGHT"),
        "prediction_seconds": float(prediction.group(1)),
        "lead_fraction": float(lead_fraction.group(1)),
    }


def _cell(point: tuple[float, float], size: float) -> tuple[int, int]:
    return (math.floor(point[0] / size), math.floor(point[1] / size))


def _center(cell: tuple[int, int], size: float) -> tuple[float, float]:
    return ((cell[0] + 0.5) * size, (cell[1] + 0.5) * size)


def _cell_distance(cell: tuple[int, int], point: tuple[float, float], size: float) -> float:
    minimum = (cell[0] * size, cell[1] * size)
    maximum = (minimum[0] + size, minimum[1] + size)
    dx = max(minimum[0] - point[0], 0.0, point[0] - maximum[0])
    dy = max(minimum[1] - point[1], 0.0, point[1] - maximum[1])
    return math.hypot(dx, dy)


def _score(cell: tuple[int, int], point: tuple[float, float], velocity: tuple[float, float],
           size: float, params: dict[str, float]) -> float:
    if cell == _cell(point, size):
        return 0.0
    current_distance = _cell_distance(cell, point, size)
    speed = math.hypot(velocity[0], velocity[1])
    if speed <= params["stop_speed_mps"]:
        return current_distance
    lead = min(speed * params["prediction_seconds"], size * params["lead_fraction"])
    predicted = (
        point[0] + velocity[0] / speed * lead,
        point[1] + velocity[1] / speed * lead,
    )
    predicted_distance = _cell_distance(cell, predicted, size)
    weight = min(speed / params["full_bias_speed_mps"], 1.0) * params["max_motion_weight"]
    return current_distance * (1.0 - weight) + predicted_distance * weight


def _sort(cells: list[tuple[int, int]], point: tuple[float, float], velocity: tuple[float, float],
          size: float, params: dict[str, float]) -> list[tuple[int, int]]:
    occupied = _cell(point, size)
    def key(cell: tuple[int, int]) -> tuple[float, ...]:
        center = _center(cell, size)
        center_d2 = (center[0] - point[0]) ** 2 + (center[1] - point[1]) ** 2
        return (0.0 if cell == occupied else 1.0, _score(cell, point, velocity, size, params), center_d2, cell[0], cell[1])
    return sorted(cells, key=key)


def _turn_path(scenario: dict) -> list[tuple[float, tuple[float, float], tuple[float, float]]]:
    size = float(scenario["cell_size"])
    speed = float(scenario["speed_mps"])
    dt = float(scenario["dt_s"])
    horizon = float(scenario["horizon_s"])
    point = [10.0, size * 0.5]
    samples = []
    for index in range(int(round(horizon / dt)) + 1):
        t = index * dt
        angle = 0.0
        for event in scenario.get("events", []):
            start = float(event["start_s"])
            duration = float(event["duration_s"])
            delta = math.radians(float(event["delta_degrees"]))
            if t <= start:
                fraction = 0.0
            elif t >= start + duration:
                fraction = 1.0
            else:
                fraction = (t - start) / duration
            angle += delta * fraction
        velocity = (speed * math.cos(angle), speed * math.sin(angle))
        samples.append((t, (point[0], point[1]), velocity))
        point[0] += velocity[0] * dt
        point[1] += velocity[1] * dt
    return samples


def _brake_reverse_path(scenario: dict) -> list[tuple[float, tuple[float, float], tuple[float, float]]]:
    size = float(scenario["cell_size"])
    speed = float(scenario["speed_mps"])
    dt = float(scenario["dt_s"])
    horizon = float(scenario["horizon_s"])
    point = [10.0, size * 0.5]
    samples = []
    for index in range(int(round(horizon / dt)) + 1):
        t = index * dt
        if t < 3.0:
            signed_speed = speed
        elif t < 5.0:
            signed_speed = speed * (1.0 - (t - 3.0) / 2.0)
        elif t < 7.0:
            signed_speed = -speed * ((t - 5.0) / 2.0)
        else:
            signed_speed = -speed
        velocity = (signed_speed, 0.0)
        samples.append((t, (point[0], point[1]), velocity))
        point[0] += velocity[0] * dt
    return samples


def _path(scenario: dict) -> list[tuple[float, tuple[float, float], tuple[float, float]]]:
    if scenario["kind"] == "turns":
        return _turn_path(scenario)
    if scenario["kind"] == "brake_reverse":
        return _brake_reverse_path(scenario)
    raise RuntimeError(f"unknown trace kind {scenario['kind']}")


def _wanted(center_cell: tuple[int, int], radius: int) -> list[tuple[int, int]]:
    return [
        (center_cell[0] + dx, center_cell[1] + dz)
        for dz in range(-radius, radius + 1)
        for dx in range(-radius, radius + 1)
    ]


def _simulate(scenario: dict, params: dict[str, float], responsive: bool) -> dict:
    samples = _path(scenario)
    size = float(scenario["cell_size"])
    radius = int(scenario["radius"])
    service_interval = float(scenario["service_interval_s"])
    first_t, first_point, first_velocity = samples[0]
    current = _cell(first_point, size)
    loaded = {current}
    load_time = {current: first_t}
    queue = _sort([c for c in _wanted(current, radius) if c not in loaded], first_point, first_velocity, size, params)
    next_service = service_interval
    misses = 0
    entries = []
    last = current

    for t, point, velocity in samples[1:]:
        current = _cell(point, size)
        if current != last:
            loaded_on_entry = current in loaded
            if not loaded_on_entry:
                misses += 1
            entries.append({"time_s": t, "cell": [current[0], current[1]], "preloaded": loaded_on_entry})
            queue = _sort([c for c in _wanted(current, radius) if c not in loaded], point, velocity, size, params)
            last = current

        while t + 1e-9 >= next_service:
            if responsive:
                queue = _sort([c for c in queue if c not in loaded], point, velocity, size, params)
            while queue and queue[0] in loaded:
                queue.pop(0)
            if queue:
                loaded_cell = queue.pop(0)
                loaded.add(loaded_cell)
                load_time.setdefault(loaded_cell, next_service)
            next_service += service_interval

    leads = []
    for entry in entries:
        cell = tuple(entry["cell"])
        if cell in load_time:
            leads.append(float(entry["time_s"]) - float(load_time[cell]))
    return {
        "misses": misses,
        "entries": len(entries),
        "mean_preload_lead_s": (sum(leads) / len(leads)) if leads else 0.0,
        "loaded_cells": len(loaded),
    }


def main() -> int:
    payload = json.loads(TRACE_PATH.read_text(encoding="utf-8"))
    if payload.get("schema_version") != 1 or payload.get("test_only") is not True:
        raise RuntimeError("RDX trace fixture must be explicitly test-only schema v1")
    params = _parameters()
    rows = []
    baseline_total = responsive_total = 0
    holdout_baseline = holdout_responsive = 0
    regressions = []

    for scenario in payload["scenarios"]:
        baseline = _simulate(scenario, params, responsive=False)
        responsive = _simulate(scenario, params, responsive=True)
        baseline_total += int(baseline["misses"])
        responsive_total += int(responsive["misses"])
        if scenario["split"] == "holdout":
            holdout_baseline += int(baseline["misses"])
            holdout_responsive += int(responsive["misses"])
        if int(responsive["misses"]) > int(baseline["misses"]):
            regressions.append(scenario["name"])
        rows.append({"name": scenario["name"], "split": scenario["split"], "baseline": baseline, "responsive": responsive})
        print(
            "RDX_STREAM_PRIORITY_CASE "
            f"{scenario['name']} baseline_misses={baseline['misses']} responsive_misses={responsive['misses']} "
            f"baseline_lead={baseline['mean_preload_lead_s']:.3f} responsive_lead={responsive['mean_preload_lead_s']:.3f}"
        )

    improvement = ((baseline_total - responsive_total) / baseline_total) if baseline_total else 0.0
    report = {
        "schema_version": 1,
        "test_only": True,
        "parameters": params,
        "baseline_misses": baseline_total,
        "responsive_misses": responsive_total,
        "miss_reduction_fraction": improvement,
        "holdout_baseline_misses": holdout_baseline,
        "holdout_responsive_misses": holdout_responsive,
        "regressions": regressions,
        "cases": rows,
    }
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    passed = (
        baseline_total >= 3
        and responsive_total == 0
        and holdout_baseline >= 2
        and holdout_responsive == 0
        and not regressions
    )
    print(
        "YARDMAN_RDX_STREAM_PRIORITY_EVAL " + ("PASS" if passed else "FAIL") +
        f" baseline_misses={baseline_total} responsive_misses={responsive_total}" +
        f" holdout_baseline={holdout_baseline} holdout_responsive={holdout_responsive}" +
        f" reduction={improvement:.4f} regressions={len(regressions)}"
    )
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
