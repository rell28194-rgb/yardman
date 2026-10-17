#!/usr/bin/env python3
"""Derive a non-destructive Yardman wheel-fitment correction proposal.

Combines exact CarX Stock Desc evidence with a Yardman candidate-audit report.
The proposal preserves the recovered model's current axle midpoint and replaces
only source-verifiable spacing/radius targets. It never rewrites the GLB.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def tyre_radius_m(tyre: dict[str, Any]) -> float:
    width_mm = float(tyre["width_mm"])
    profile = float(tyre.get("profile_percent", tyre.get("profile", 0.0)))
    rim_in = float(tyre["rim_in"])
    diameter_mm = rim_in * 25.4 + 2.0 * width_mm * profile / 100.0
    return diameter_mm / 2000.0


def average(values: list[float]) -> float:
    return sum(values) / len(values)


def build(stock: dict[str, Any], candidate: dict[str, Any]) -> dict[str, Any]:
    pivots = candidate["metrics"]["wheel_pivots"]
    fl = [float(value) for value in pivots["FrontWheelLeft"]]
    fr = [float(value) for value in pivots["FrontWheelRight"]]
    rl = [float(value) for value in pivots["RearWheelLeft"]]
    rr = [float(value) for value in pivots["RearWheelRight"]]

    current_front_z = average([fl[2], fr[2]])
    current_rear_z = average([rl[2], rr[2]])
    axle_midpoint_z = average([current_front_z, current_rear_z])
    source_wheelbase = float(stock["wheelbase_m"])
    source_front_track = float(stock["front_track_m"])
    source_rear_track = float(stock["rear_track_m"])
    target_front_z = axle_midpoint_z - source_wheelbase * 0.5
    target_rear_z = axle_midpoint_z + source_wheelbase * 0.5
    front_radius = tyre_radius_m(stock["front_tyre"])
    rear_radius = tyre_radius_m(stock["rear_tyre"])

    current_wheel_geometry = candidate["metrics"].get("wheel_geometry", {})
    current_front_radii = [
        float(current_wheel_geometry.get(name, {}).get("radius_m", 0.0))
        for name in ("FrontWheelLeftSpin", "FrontWheelRightSpin")
    ]
    current_rear_radii = [
        float(current_wheel_geometry.get(name, {}).get("radius_m", 0.0))
        for name in ("RearWheelLeftSpin", "RearWheelRightSpin")
    ]
    current_front_radius = average(current_front_radii)
    current_rear_radius = average(current_rear_radii)

    target = {
        "FrontWheelLeft": [-source_front_track * 0.5, fl[1], target_front_z],
        "FrontWheelRight": [source_front_track * 0.5, fr[1], target_front_z],
        "RearWheelLeft": [-source_rear_track * 0.5, rl[1], target_rear_z],
        "RearWheelRight": [source_rear_track * 0.5, rr[1], target_rear_z],
    }
    current = {
        "FrontWheelLeft": fl,
        "FrontWheelRight": fr,
        "RearWheelLeft": rl,
        "RearWheelRight": rr,
    }
    deltas = {
        name: [round(target[name][axis] - current[name][axis], 9) for axis in range(3)]
        for name in target
    }
    max_position_delta = max(abs(value) for row in deltas.values() for value in row)
    max_radius_delta = max(
        abs(current_front_radius - front_radius),
        abs(current_rear_radius - rear_radius),
    )

    return {
        "format_version": 1,
        "tool": "yardman_carx_stock_fitment_derivation",
        "identity": candidate.get("identity", stock.get("stock_name", "")),
        "source_stock_name": stock.get("stock_name", ""),
        "candidate_sha256": candidate.get("sha256", ""),
        "source_payload_sha256": stock.get("payload_sha256", ""),
        "policy": {
            "proposal_only": True,
            "preserve_current_axle_midpoint": True,
            "preserve_current_pivot_y_until_body_origin_is_verified": True,
            "requires_corrected_render_before_promotion": True,
        },
        "current": {
            "wheel_pivots_m": current,
            "front_wheel_radius_m": round(current_front_radius, 9),
            "rear_wheel_radius_m": round(current_rear_radius, 9),
            "axle_midpoint_z_m": round(axle_midpoint_z, 9),
        },
        "source_target": {
            "wheel_pivots_m": {name: [round(value, 9) for value in row] for name, row in target.items()},
            "front_wheel_radius_m": round(front_radius, 9),
            "rear_wheel_radius_m": round(rear_radius, 9),
            "front_tyre": stock["front_tyre"],
            "rear_tyre": stock["rear_tyre"],
        },
        "delta_target_minus_current_m": deltas,
        "max_position_delta_m": round(max_position_delta, 9),
        "max_radius_delta_m": round(max_radius_delta, 9),
        "requires_rerig_or_refit": max_position_delta > 0.005 or max_radius_delta > 0.005,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("stock_desc_json", type=Path)
    parser.add_argument("candidate_audit_json", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    stock = json.loads(args.stock_desc_json.read_text(encoding="utf-8"))
    candidate = json.loads(args.candidate_audit_json.read_text(encoding="utf-8"))
    result = build(stock, candidate)
    text = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
    print(text, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
