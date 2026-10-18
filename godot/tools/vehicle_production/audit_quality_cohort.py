#!/usr/bin/env python3
"""Fail closed when the representative vehicle cohort loses source evidence.

This is intentionally a provenance/selector gate, not a visual acceptance claim.
Visual, rig, hook and lifecycle acceptance remains a separate runtime test.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

COHORT = {
    "delorean_dmc12": {
        "source_identity": "DeloreanDMC12",
        "source_sha256": "0f0d2e1f12bf5cd8c9da48c6ebd3480fca7573adb1089371a6f943bf5b2be763",
        "beta2_car_id": 223,
        "beta2_identity": "DeLorean DMC-12",
    },
    "corvette_c7": {
        "source_identity": "CorvetteC7",
        "source_sha256": "a73a025b211c05e74514899f98511195742121168cb187473c41bbc7ae1b0c67",
        "beta2_car_id": 40,
        "beta2_identity": "corvette c7",
    },
}


def load_registry(path: Path) -> dict[str, dict]:
    document = json.loads(path.read_text())
    if document.get("format_version") != 1:
        raise SystemExit(f"unsupported registry format: {path}")
    entries: dict[str, dict] = {}
    for entry in document.get("vehicles", []):
        vehicle_id = entry.get("id")
        if not vehicle_id:
            raise SystemExit(f"vehicle without selector id: {path}")
        if vehicle_id in entries:
            raise SystemExit(f"duplicate selector id {vehicle_id}: {path}")
        entries[vehicle_id] = entry
    return entries


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--supplemental", type=Path, default=Path("godot/data/vehicle_fleet_supplemental.json"))
    parser.add_argument("--hero-root", type=Path, default=Path("godot/assets/vehicles"))
    args = parser.parse_args()

    entries = load_registry(args.supplemental)
    failures: list[str] = []
    report: dict[str, dict] = {}
    for vehicle_id, expected in COHORT.items():
        entry = entries.get(vehicle_id)
        if entry is None:
            failures.append(f"{vehicle_id}: selector missing")
            continue
        for key, value in expected.items():
            if entry.get(key) != value:
                failures.append(f"{vehicle_id}: {key} changed: {entry.get(key)!r} != {value!r}")
        hero_scene = str(entry.get("hero_scene", ""))
        if not hero_scene or Path(hero_scene).name != hero_scene:
            failures.append(f"{vehicle_id}: hero_scene is not selector-safe: {hero_scene!r}")
        if not entry.get("source_unit"):
            failures.append(f"{vehicle_id}: Beta1/source unit missing")
        dimensions = entry.get("dimensions_m")
        if not isinstance(dimensions, list) or len(dimensions) != 3 or any(float(v) <= 0.0 for v in dimensions):
            failures.append(f"{vehicle_id}: invalid source dimensions")
        for key in ("wheelbase_m", "track_width_m", "wheel_radius_m"):
            if float(entry.get(key, 0.0)) <= 0.0:
                failures.append(f"{vehicle_id}: invalid {key}")
        report[vehicle_id] = {
            "source_identity": entry.get("source_identity"),
            "source_sha256": entry.get("source_sha256"),
            "beta2_car_id": entry.get("beta2_car_id"),
            "beta2_identity": entry.get("beta2_identity"),
            "hero_scene": hero_scene,
            "status": "provenance_gate_only",
        }

    print(json.dumps(report, indent=2, sort_keys=True))
    if failures:
        for failure in failures:
            print("YARDMAN_VEHICLE_COHORT_PROVENANCE_FAIL", failure)
        return 1
    print("YARDMAN_VEHICLE_COHORT_PROVENANCE_PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
