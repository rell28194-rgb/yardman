#!/usr/bin/env python3
"""Validate a Yardman per-car LOD chain from audit JSON outputs."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

DEFAULT_LIMITS = {
    "LOD0": 120_000,
    "LOD1": 45_000,
    "LOD2": 15_000,
    "LOD3": 4_000,
}


def load(path: Path):
    data = json.loads(path.read_text(encoding="utf-8"))
    if not data.get("policy", {}).get("pass", False):
        raise ValueError(f"source audit failed: {path}")
    return data["metrics"]


def main() -> int:
    parser = argparse.ArgumentParser()
    for level in ("lod0", "lod1", "lod2", "lod3"):
        parser.add_argument(f"--{level}", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    supplied = [(level.upper(), getattr(args, level)) for level in ("lod0", "lod1", "lod2", "lod3") if getattr(args, level)]
    if not supplied:
        parser.error("at least one LOD audit is required")

    reports = []
    failures = []
    previous_triangles = None
    for level, path in supplied:
        metrics = load(path)
        triangles = int(metrics["triangles"])
        cap = DEFAULT_LIMITS[level]
        cap_pass = triangles <= cap
        if not cap_pass:
            failures.append(f"{level} triangle cap {triangles}>{cap}")
        if previous_triangles is not None and triangles >= previous_triangles:
            failures.append(f"{level} must be cheaper than previous LOD ({triangles}>={previous_triangles})")
        reports.append({
            "level": level,
            "file": metrics["file"],
            "triangles": triangles,
            "triangle_cap": cap,
            "cap_pass": cap_pass,
            "materials": metrics["materials_referenced"],
            "textures": metrics["textures"],
            "estimated_geometry_bytes": metrics["estimated_geometry_bytes"],
        })
        previous_triangles = triangles

    result = {
        "format_version": 1,
        "tool": "yardman_vehicle_lod_chain",
        "pass": not failures,
        "lods": reports,
        "failures": failures,
        "distance_policy_m": {
            "LOD0": [0, 18],
            "LOD1": [18, 55],
            "LOD2": [55, 140],
            "LOD3": [140, 300],
            "impostor_or_cull": [300, None],
        },
    }
    text = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
    print(text, end="")
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
