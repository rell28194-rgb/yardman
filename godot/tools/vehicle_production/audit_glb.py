#!/usr/bin/env python3
"""Dependency-free GLB vehicle audit for Yardman production assets.

Reads glTF 2.0 binary containers, reports render-budget metrics, and validates
Yardman's vehicle rig contract without importing the asset into the game.
"""
from __future__ import annotations

import argparse
import json
import struct
from pathlib import Path
from typing import Any

GLB_MAGIC = 0x46546C67
JSON_CHUNK = 0x4E4F534A
COMPONENT_BYTES = {5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4}
TYPE_COMPONENTS = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT2": 4, "MAT3": 9, "MAT4": 16}
REQUIRED_RIG_NODES = (
    "BodyShell",
    "FrontWheelLeft", "FrontWheelRight", "RearWheelLeft", "RearWheelRight",
    "FrontWheelLeftSpin", "FrontWheelRightSpin", "RearWheelLeftSpin", "RearWheelRightSpin",
)


def load_glb(path: Path) -> dict[str, Any]:
    raw = path.read_bytes()
    if len(raw) < 20:
        raise ValueError("file too small for GLB")
    magic, version, declared = struct.unpack_from("<III", raw, 0)
    if magic != GLB_MAGIC or version != 2:
        raise ValueError("not a glTF 2.0 binary container")
    if declared != len(raw):
        raise ValueError(f"declared length {declared} != file length {len(raw)}")
    offset = 12
    document = None
    while offset + 8 <= len(raw):
        length, chunk_type = struct.unpack_from("<II", raw, offset)
        offset += 8
        end = offset + length
        if end > len(raw):
            raise ValueError("chunk extends past EOF")
        if chunk_type == JSON_CHUNK:
            document = json.loads(raw[offset:end].decode("utf-8").rstrip(" \t\r\n\x00"))
            break
        offset = end
    if not isinstance(document, dict):
        raise ValueError("GLB has no JSON chunk")
    return document


def accessor_count(doc: dict[str, Any], index: int | None) -> int:
    if index is None:
        return 0
    accessors = doc.get("accessors", [])
    if not isinstance(index, int) or index < 0 or index >= len(accessors):
        return 0
    return int(accessors[index].get("count", 0))


def accessor_byte_estimate(doc: dict[str, Any], index: int | None) -> int:
    if index is None:
        return 0
    accessors = doc.get("accessors", [])
    if not isinstance(index, int) or index < 0 or index >= len(accessors):
        return 0
    accessor = accessors[index]
    count = int(accessor.get("count", 0))
    component_size = COMPONENT_BYTES.get(int(accessor.get("componentType", 0)), 0)
    components = TYPE_COMPONENTS.get(str(accessor.get("type", "")), 0)
    return count * component_size * components


def triangle_count(doc: dict[str, Any], primitive: dict[str, Any]) -> int:
    mode = int(primitive.get("mode", 4))
    indices = accessor_count(doc, primitive.get("indices"))
    positions = accessor_count(doc, (primitive.get("attributes") or {}).get("POSITION"))
    n = indices or positions
    if mode == 4:
        return n // 3
    if mode in (5, 6):
        return max(0, n - 2)
    return 0


def collect_metrics(doc: dict[str, Any], path: Path) -> dict[str, Any]:
    meshes = doc.get("meshes", [])
    nodes = doc.get("nodes", [])
    materials = doc.get("materials", [])
    images = doc.get("images", [])
    textures = doc.get("textures", [])
    samplers = doc.get("samplers", [])

    triangles = 0
    position_vertices = 0
    index_bytes = 0
    vertex_bytes = 0
    primitive_count = 0
    used_materials: set[int] = set()
    for mesh in meshes:
        for primitive in mesh.get("primitives", []):
            primitive_count += 1
            triangles += triangle_count(doc, primitive)
            attrs = primitive.get("attributes") or {}
            position_vertices += accessor_count(doc, attrs.get("POSITION"))
            index_bytes += accessor_byte_estimate(doc, primitive.get("indices"))
            for accessor_index in attrs.values():
                vertex_bytes += accessor_byte_estimate(doc, accessor_index)
            if isinstance(primitive.get("material"), int):
                used_materials.add(int(primitive["material"]))

    node_names = {str(node.get("name", "")) for node in nodes}
    missing_rig = [name for name in REQUIRED_RIG_NODES if name not in node_names]
    material_names = [str(m.get("name", "")) for m in materials]

    return {
        "file": path.name,
        "bytes": path.stat().st_size,
        "nodes": len(nodes),
        "meshes": len(meshes),
        "mesh_primitives": primitive_count,
        "triangles": triangles,
        "position_vertices_across_primitives": position_vertices,
        "materials": len(materials),
        "materials_referenced": len(used_materials),
        "material_names": material_names,
        "textures": len(textures),
        "images": len(images),
        "samplers": len(samplers),
        "estimated_vertex_attribute_bytes": vertex_bytes,
        "estimated_index_bytes": index_bytes,
        "estimated_geometry_bytes": vertex_bytes + index_bytes,
        "rig_contract": {
            "pass": not missing_rig,
            "missing_nodes": missing_rig,
            "required_nodes": list(REQUIRED_RIG_NODES),
        },
    }


def policy_result(metrics: dict[str, Any], args: argparse.Namespace) -> dict[str, Any]:
    checks: list[dict[str, Any]] = []

    def check(name: str, ok: bool, actual: Any, limit: Any) -> None:
        checks.append({"name": name, "pass": bool(ok), "actual": actual, "limit": limit})

    check("triangle_cap", metrics["triangles"] <= args.max_triangles, metrics["triangles"], args.max_triangles)
    check("material_cap", metrics["materials_referenced"] <= args.max_materials, metrics["materials_referenced"], args.max_materials)
    check("texture_cap", metrics["textures"] <= args.max_textures, metrics["textures"], args.max_textures)
    if args.require_rig:
        check("yardman_rig_contract", metrics["rig_contract"]["pass"], metrics["rig_contract"]["missing_nodes"], "none missing")
    return {"pass": all(c["pass"] for c in checks), "checks": checks}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("glb", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--max-triangles", type=int, default=120_000)
    parser.add_argument("--max-materials", type=int, default=16)
    parser.add_argument("--max-textures", type=int, default=16)
    parser.add_argument("--require-rig", action="store_true")
    args = parser.parse_args()

    try:
        doc = load_glb(args.glb)
        metrics = collect_metrics(doc, args.glb)
        report = {
            "format_version": 1,
            "tool": "yardman_vehicle_glb_audit",
            "metrics": metrics,
            "policy": policy_result(metrics, args),
        }
    except Exception as exc:
        report = {"format_version": 1, "tool": "yardman_vehicle_glb_audit", "error": str(exc), "policy": {"pass": False}}

    text = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
    print(text, end="")
    return 0 if report.get("policy", {}).get("pass") else 1


if __name__ == "__main__":
    raise SystemExit(main())
