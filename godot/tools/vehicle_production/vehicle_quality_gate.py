#!/usr/bin/env python3
"""Evidence-based quality gate for Yardman production vehicles.

This gate deliberately separates source fidelity from Android runtime cost. A vehicle
must preserve close-range detail (body, cabin, lights, glass and wheel/brake detail)
while also carrying a validated LOD chain. It never approves a vehicle merely because
it fits a triangle budget.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

REQUIRED_DETAIL = (
    "exterior_body",
    "interior_cabin",
    "lighting",
    "glass",
    "wheels",
    "brakes",
)
REQUIRED_LODS = ("lod0", "lod1", "lod2", "lod3")


def load(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def gate(spec: dict[str, Any]) -> dict[str, Any]:
    checks: list[dict[str, Any]] = []

    def check(name: str, ok: bool, actual: Any, requirement: Any) -> None:
        checks.append({"name": name, "pass": bool(ok), "actual": actual, "requirement": requirement})

    identity = str(spec.get("identity", "")).strip()
    rights = str(spec.get("rights_status", "")).strip()
    provenance = spec.get("provenance") or {}
    detail = spec.get("detail") or {}
    lods = spec.get("lods") or {}

    check("identity_resolved", bool(identity), identity or None, "non-empty resolved identity")
    check("rights_cleared", rights == "owner_authorized_non_porsche", rights or None, "owner_authorized_non_porsche")
    check("source_path_recorded", bool(provenance.get("source_path")), provenance.get("source_path"), "exact source path")
    check("source_hash_recorded", bool(provenance.get("sha256")), provenance.get("sha256"), "SHA-256 provenance")

    for key in REQUIRED_DETAIL:
        item = detail.get(key) or {}
        check(f"detail_{key}", bool(item.get("present")) and bool(item.get("evidence")), item, "present with evidence")

    previous_triangles: int | None = None
    for name in REQUIRED_LODS:
        lod = lods.get(name) or {}
        triangles = lod.get("triangles")
        valid_triangles = isinstance(triangles, int) and triangles > 0
        check(f"{name}_exists", bool(lod.get("path")) and valid_triangles, lod, "path + positive triangle count")
        if previous_triangles is not None and valid_triangles:
            check(f"{name}_reduces_geometry", triangles < previous_triangles, triangles, f"< {previous_triangles}")
        if valid_triangles:
            previous_triangles = triangles

    lod0 = lods.get("lod0") or {}
    lod3 = lods.get("lod3") or {}
    if isinstance(lod0.get("triangles"), int) and isinstance(lod3.get("triangles"), int) and lod0["triangles"] > 0:
        ratio = lod3["triangles"] / lod0["triangles"]
        check("lod3_reduction_ratio", ratio <= 0.12, round(ratio, 5), "<= 0.12 of LOD0")

    visual = spec.get("visual_validation") or {}
    check("close_render_review", visual.get("close") == "pass", visual.get("close"), "pass")
    check("mid_render_review", visual.get("mid") == "pass", visual.get("mid"), "pass")
    check("far_render_review", visual.get("far") == "pass", visual.get("far"), "pass")
    check("android_runtime_pending_not_hidden", visual.get("android_device") in {"pass", "pending"}, visual.get("android_device"), "pass or explicit pending")

    return {
        "format_version": 1,
        "tool": "yardman_vehicle_quality_gate",
        "identity": identity,
        "pass": all(c["pass"] for c in checks),
        "checks": checks,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("spec", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    report = gate(load(args.spec))
    text = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
    print(text, end="")
    return 0 if report["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
