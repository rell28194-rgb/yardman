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
    if not isinstance(data, dict) or not isinstance(data.get("policy"), dict) or not isinstance(data.get("metrics"), dict):
        raise ValueError(f"invalid source audit structure: {path}")
    if data.get("policy", {}).get("pass") is not True:
        raise ValueError(f"source audit failed: {path}")
    metrics = data["metrics"]
    if not isinstance(metrics.get("file"), str) or not isinstance(metrics.get("rig_contract", {}), dict):
        raise ValueError(f"invalid asset identity or rig metadata: {path}")
    for name in ("triangles", "materials_referenced", "textures", "estimated_geometry_bytes"):
        if type(metrics.get(name)) is not int or metrics[name] < 0:
            raise ValueError(f"invalid {name} in source audit: {path}")
    if metrics["triangles"] == 0 or metrics["estimated_geometry_bytes"] == 0:
        raise ValueError(f"empty geometry in source audit: {path}")
    return metrics


def validate(supplied: list[tuple[str, Path]], allow_partial: bool = False) -> dict:
    """Partial progress can be audited, but can never claim production readiness."""
    reports = []
    failures = []
    missing = [level for level in DEFAULT_LIMITS if level not in dict(supplied)]
    if missing and not allow_partial:
        failures.append("missing required LODs: " + ", ".join(missing))
    previous = None
    for level, path in supplied:
        try:
            metrics = load(path)
        except (OSError, ValueError, KeyError, TypeError) as exc:
            failures.append(f"{level}: {exc}")
            continue
        triangles = metrics["triangles"]
        cap = DEFAULT_LIMITS[level]
        cap_pass = triangles <= cap
        if not cap_pass:
            failures.append(f"{level} triangle cap {triangles}>{cap}")
        if previous is not None:
            if triangles >= previous["triangles"]:
                failures.append(f"{level} must have fewer triangles than previous LOD ({triangles}>={previous['triangles']})")
            if metrics["estimated_geometry_bytes"] >= previous["estimated_geometry_bytes"]:
                failures.append(f"{level} decoded geometry memory must decrease")
            for field in ("materials_referenced", "textures"):
                if metrics[field] > previous[field]:
                    failures.append(f"{level} {field} must not increase")
            texture_bytes = metrics.get("estimated_texture_rgba8_mip_bytes")
            previous_texture_bytes = previous.get("estimated_texture_rgba8_mip_bytes")
            if type(texture_bytes) is int and type(previous_texture_bytes) is int and texture_bytes > previous_texture_bytes:
                failures.append(f"{level} texture memory estimate must not increase")
        rig = metrics.get("rig_contract", {})
        if rig.get("pass") is not True:
            failures.append(f"{level} wheel/body rig contract is not verified")
        reports.append({
            "level": level,
            "file": metrics["file"],
            "triangles": triangles,
            "triangle_cap": cap,
            "cap_pass": cap_pass,
            "materials": metrics["materials_referenced"],
            "textures": metrics["textures"],
            "estimated_geometry_bytes": metrics["estimated_geometry_bytes"],
            "estimated_texture_rgba8_mip_bytes": metrics.get("estimated_texture_rgba8_mip_bytes"),
            "image_dimensions": metrics.get("image_dimensions", []),
            "sha256": metrics.get("sha256"),
            "rig_pass": rig.get("pass") is True,
        })
        previous = metrics

    return {
        "format_version": 2,
        "tool": "yardman_vehicle_lod_chain",
        "pass": not failures,
        "complete": not missing,
        "static_chain_ready": not failures and not missing,
        "missing_lods": missing,
        "lods": reports,
        "failures": failures,
        "distance_policy_m": {
            "LOD0": [0, 18], "LOD1": [18, 55], "LOD2": [55, 140],
            "LOD3": [140, 300], "impostor_or_cull": [300, None],
        },
        "distance_policy_status": "proposed only; runtime switching, hysteresis, visual continuity and unloading require independent tests",
        "readiness_scope": "static asset budgets and rig only; does not establish runtime, Android, rights or visual acceptance",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    for level in ("lod0", "lod1", "lod2", "lod3"):
        parser.add_argument(f"--{level}", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--allow-partial", action="store_true", help="audit progress without claiming production readiness")
    args = parser.parse_args()

    supplied = [(level.upper(), getattr(args, level)) for level in ("lod0", "lod1", "lod2", "lod3") if getattr(args, level)]
    if not supplied:
        parser.error("at least one LOD audit is required")

    result = validate(supplied, args.allow_partial)
    text = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
    print(text, end="")
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
