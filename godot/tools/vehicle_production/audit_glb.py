#!/usr/bin/env python3
"""Dependency-free GLB vehicle audit for Yardman production assets.

Reads glTF 2.0 binary containers, reports render-budget metrics, and validates
Yardman's vehicle rig contract without importing the asset into the game.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
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
    while offset < len(raw):
        if offset + 8 > len(raw):
            raise ValueError("truncated chunk header")
        length, chunk_type = struct.unpack_from("<II", raw, offset)
        offset += 8
        end = offset + length
        if end > len(raw):
            raise ValueError("chunk extends past EOF")
        if length % 4:
            raise ValueError("GLB chunk length is not four-byte aligned")
        if chunk_type == JSON_CHUNK:
            if document is not None or offset != 20:
                raise ValueError("GLB must start with exactly one JSON chunk")
            document = json.loads(raw[offset:end].decode("utf-8").rstrip(" \t\r\n\x00"))
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
    # A present but invalid/empty index accessor must not fall back to positions.
    n = indices if "indices" in primitive else positions
    if mode == 4:
        return n // 3
    if mode in (5, 6):
        return max(0, n - 2)
    return 0


def mesh_metrics(doc: dict[str, Any]) -> list[dict[str, int]]:
    result: list[dict[str, int]] = []
    for mesh in doc.get("meshes", []):
        triangles = 0
        positions = 0
        primitives = 0
        for primitive in mesh.get("primitives", []):
            primitives += 1
            triangles += triangle_count(doc, primitive)
            positions += accessor_count(doc, (primitive.get("attributes") or {}).get("POSITION"))
        result.append({"triangles": triangles, "position_vertices": positions, "primitives": primitives})
    return result


def active_scene_nodes(doc: dict[str, Any]) -> tuple[set[int], list[str]]:
    """Resolve only the selected scene; hidden/export leftovers are not draws."""
    nodes = doc.get("nodes", [])
    scenes = doc.get("scenes", [])
    errors: list[str] = []
    if not scenes:
        return set(), ["no scene available for vehicle rendering"]
    scene = doc.get("scene", 0)
    if type(scene) is not int or not 0 <= scene < len(scenes):
        return set(), ["invalid default scene reference"]
    active: set[int] = set()
    visiting: set[int] = set()
    def visit(index: int, parent: int | None) -> None:
        if type(index) is not int or not 0 <= index < len(nodes):
            errors.append(f"invalid node reference {index}")
            return
        if index in visiting:
            errors.append(f"node hierarchy cycle at {index}")
            return
        if index in active:
            errors.append(f"node {index} has duplicate scene ownership")
            return
        active.add(index)
        visiting.add(index)
        for child in nodes[index].get("children", []):
            visit(child, index)
        visiting.remove(index)

    for root in scenes[scene].get("nodes", []):
        visit(root, None)
    return active, errors


def rig_metrics(doc: dict[str, Any], active: set[int]) -> dict[str, Any]:
    nodes = doc.get("nodes", [])
    matches = {name: [i for i in active if nodes[i].get("name") == name] for name in REQUIRED_RIG_NODES}
    missing = [name for name, ids in matches.items() if not ids]
    errors = [f"ambiguous rig node: {name}" for name, ids in matches.items() if len(ids) > 1]

    def has_mesh(root: int, seen: set[int] | None = None) -> bool:
        seen = seen if seen is not None else set()
        if root in seen or root not in active:
            return False
        seen.add(root)
        node = nodes[root]
        return type(node.get("mesh")) is int or any(has_mesh(child, seen) for child in node.get("children", []))

    for name in ("BodyShell", *REQUIRED_RIG_NODES[5:]):
        if len(matches[name]) == 1 and not has_mesh(matches[name][0]):
            errors.append(f"{name} has no render mesh descendant")
    for wheel in REQUIRED_RIG_NODES[1:5]:
        if len(matches[wheel]) == len(matches[wheel + "Spin"]) == 1:
            pivot, spin = matches[wheel][0], matches[wheel + "Spin"][0]
            if spin not in nodes[pivot].get("children", []):
                errors.append(f"{wheel}Spin must be a child of {wheel}")
    return {"pass": not missing and not errors, "missing_nodes": missing,
            "errors": errors, "required_nodes": list(REQUIRED_RIG_NODES)}


def geometry_errors(doc: dict[str, Any]) -> list[str]:
    """Reject malformed topology/reference metadata instead of budgeting it as zero."""
    errors = []
    accessors = doc.get("accessors", [])
    for mesh_id, mesh in enumerate(doc.get("meshes", [])):
        for primitive_id, primitive in enumerate(mesh.get("primitives", [])):
            label = f"mesh {mesh_id} primitive {primitive_id}"
            attrs = primitive.get("attributes", {})
            if "POSITION" not in attrs:
                errors.append(f"{label}: missing POSITION")
            refs = list(attrs.values())
            if "indices" in primitive:
                refs.append(primitive["indices"])
            for target in primitive.get("targets", []):
                refs.extend(target.values())
            for ref in refs:
                if type(ref) is not int or not 0 <= ref < len(accessors):
                    errors.append(f"{label}: invalid accessor {ref}")
                    continue
                a = accessors[ref]
                if (type(a.get("count")) is not int or a["count"] <= 0
                        or a.get("componentType") not in COMPONENT_BYTES
                        or a.get("type") not in TYPE_COMPONENTS):
                    errors.append(f"{label}: malformed accessor {ref}")
            position = attrs.get("POSITION")
            if type(position) is int and 0 <= position < len(accessors):
                if accessors[position].get("type") != "VEC3":
                    errors.append(f"{label}: POSITION must be VEC3")
                count = accessor_count(doc, position)
                for attribute, ref in attrs.items():
                    if accessor_count(doc, ref) != count:
                        errors.append(f"{label}: {attribute} count differs from POSITION")
                for target in primitive.get("targets", []):
                    for ref in target.values():
                        if accessor_count(doc, ref) != count:
                            errors.append(f"{label}: morph target count differs from POSITION")
            if "material" in primitive:
                material = primitive["material"]
                if type(material) is not int or not 0 <= material < len(doc.get("materials", [])):
                    errors.append(f"{label}: invalid material {material}")
            mode = primitive.get("mode", 4)
            n = accessor_count(doc, primitive.get("indices") if "indices" in primitive else attrs.get("POSITION"))
            if mode not in (4, 5, 6):
                errors.append(f"{label}: non-triangle primitive mode {mode}")
            elif (mode == 4 and n % 3) or (mode in (5, 6) and n < 3):
                errors.append(f"{label}: incomplete triangle topology")
            index = primitive.get("indices")
            if type(index) is int and 0 <= index < len(accessors):
                a = accessors[index]
                if a.get("type") != "SCALAR" or a.get("componentType") not in (5121, 5123, 5125):
                    errors.append(f"{label}: invalid index accessor format")
    return errors


def image_dimensions(payload: bytes) -> tuple[int, int] | None:
    """Read PNG/JPEG dimensions without decoding pixel data or adding dependencies."""
    if payload.startswith(b"\x89PNG\r\n\x1a\n") and len(payload) >= 24 and payload[12:16] == b"IHDR":
        return struct.unpack_from(">II", payload, 16)
    if payload.startswith(b"\xff\xd8"):
        offset = 2
        while offset < len(payload):
            if payload[offset] != 0xFF:
                return None
            while offset < len(payload) and payload[offset] == 0xFF:
                offset += 1
            if offset >= len(payload):
                return None
            marker = payload[offset]
            offset += 1
            if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
                continue
            if marker in (0xD9, 0xDA) or offset + 2 > len(payload):
                return None
            length = struct.unpack_from(">H", payload, offset)[0]
            if length < 2 or offset + length > len(payload):
                return None
            if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF) and length >= 8:
                height, width = struct.unpack_from(">HH", payload, offset + 3)
                return width, height
            offset += length
    return None


def texture_metrics(doc: dict[str, Any], path: Path) -> dict[str, Any]:
    # Container size and encoded JPEG/PNG size are not decoded GPU memory.
    raw = path.read_bytes()
    binary = b""
    if raw[:4] == b"glTF":
        offset = 12
        while offset + 8 <= len(raw):
            size, kind = struct.unpack_from("<II", raw, offset)
            offset += 8
            if kind == 0x004E4942:
                binary = raw[offset:offset + size]
            offset += size
    images = []
    unresolved = []
    reference_errors = []
    total = 0
    for texture_id, texture in enumerate(doc.get("textures", [])):
        image_id = texture.get("source")
        if image_id is None:
            image_id = texture.get("extensions", {}).get("KHR_texture_basisu", {}).get("source")
        if type(image_id) is not int or not 0 <= image_id < len(doc.get("images", [])):
            reference_errors.append(f"texture {texture_id}: invalid image reference {image_id}")
        if "sampler" in texture:
            sampler = texture["sampler"]
            if type(sampler) is not int or not 0 <= sampler < len(doc.get("samplers", [])):
                reference_errors.append(f"texture {texture_id}: invalid sampler {sampler}")

    def check_material_textures(value: Any) -> None:
        if isinstance(value, dict):
            for key, item in value.items():
                if key.endswith("Texture") and isinstance(item, dict):
                    index = item.get("index")
                    if type(index) is not int or not 0 <= index < len(doc.get("textures", [])):
                        reference_errors.append(f"material {key}: invalid texture {index}")
                check_material_textures(item)
        elif isinstance(value, list):
            for item in value:
                check_material_textures(item)

    check_material_textures(doc.get("materials", []))
    for image_id, item in enumerate(doc.get("images", [])):
        payload = b""
        try:
            if "bufferView" in item:
                view = doc["bufferViews"][item["bufferView"]]
                start, size = view.get("byteOffset", 0), view["byteLength"]
                if view.get("buffer", 0) != 0 or start < 0 or size < 0 or start + size > len(binary):
                    raise ValueError("image buffer range is invalid")
                payload = binary[start:start + size]
            elif item.get("uri", "").startswith("data:"):
                header, data = item["uri"].split(",", 1)
                if not header.endswith(";base64"):
                    raise ValueError("image data URI is not base64")
                payload = base64.b64decode(data, validate=True)
            elif item.get("uri"):
                local = (path.parent / item["uri"]).resolve()
                if not local.is_relative_to(path.parent.resolve()):
                    raise ValueError("image URI is not local to this GLB directory")
                payload = local.read_bytes()
            dimensions = image_dimensions(payload)
            if not dimensions or min(dimensions) <= 0:
                raise ValueError("dimensions unresolved (supported: PNG/JPEG)")
            width, height = dimensions
            mip_bytes, w, h = 0, width, height
            while True:
                mip_bytes += w * h * 4
                if w == h == 1:
                    break
                w, h = max(1, w // 2), max(1, h // 2)
            total += mip_bytes
            images.append({"image": image_id, "width": width, "height": height,
                           "encoded_bytes": len(payload), "rgba8_full_mip_bytes": mip_bytes})
        except (OSError, ValueError, KeyError, IndexError, TypeError) as exc:
            unresolved.append({"image": image_id, "reason": str(exc)})
    return {"image_dimensions": images, "unresolved_images": unresolved,
            "texture_reference_errors": reference_errors,
            "estimated_texture_rgba8_mip_bytes": total if not unresolved else None,
            "texture_memory_basis": "one RGBA8 allocation with full mip chain per stored image; estimate excludes staging copies and driver overhead; Android compression may reduce residency"}


def collect_metrics(doc: dict[str, Any], path: Path) -> dict[str, Any]:
    meshes = doc.get("meshes", [])
    nodes = doc.get("nodes", [])
    materials = doc.get("materials", [])
    images = doc.get("images", [])
    textures = doc.get("textures", [])
    samplers = doc.get("samplers", [])

    unique_triangles = 0
    unique_position_vertices = 0
    index_bytes = 0
    vertex_bytes = 0
    primitive_count = 0
    used_materials: set[int] = set()
    vertex_accessors: set[int] = set()
    index_accessors: set[int] = set()
    per_mesh = mesh_metrics(doc)
    for mesh_index, mesh in enumerate(meshes):
        unique_triangles += per_mesh[mesh_index]["triangles"]
        unique_position_vertices += per_mesh[mesh_index]["position_vertices"]
        primitive_count += per_mesh[mesh_index]["primitives"]
        for primitive in mesh.get("primitives", []):
            attrs = primitive.get("attributes") or {}
            if isinstance(primitive.get("indices"), int):
                index_accessors.add(primitive["indices"])
            vertex_accessors.update(attrs.values())
            for target in primitive.get("targets", []):
                vertex_accessors.update(target.values())
            if isinstance(primitive.get("material"), int):
                used_materials.add(int(primitive["material"]))
    index_bytes = sum(accessor_byte_estimate(doc, i) for i in index_accessors)
    vertex_bytes = sum(accessor_byte_estimate(doc, i) for i in vertex_accessors)

    scene_triangles = 0
    scene_position_vertices = 0
    mesh_instance_count = 0
    invalid_mesh_refs = 0
    active, scene_errors = active_scene_nodes(doc)
    for node_id in active:
        node = nodes[node_id]
        mesh_index = node.get("mesh")
        if not isinstance(mesh_index, int):
            continue
        if mesh_index < 0 or mesh_index >= len(per_mesh):
            invalid_mesh_refs += 1
            continue
        mesh_instance_count += 1
        scene_triangles += per_mesh[mesh_index]["triangles"]
        scene_position_vertices += per_mesh[mesh_index]["position_vertices"]

    material_names = [str(m.get("name", "")) for m in materials]

    return {
        "file": path.name,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "bytes": path.stat().st_size,
        "nodes": len(nodes),
        "active_scene_nodes": len(active),
        "scene_errors": scene_errors,
        "geometry_errors": geometry_errors(doc),
        "meshes": len(meshes),
        "mesh_instances": mesh_instance_count,
        "invalid_mesh_references": invalid_mesh_refs,
        "mesh_primitives": primitive_count,
        "triangles": scene_triangles,
        "scene_instance_triangles": scene_triangles,
        "unique_mesh_triangles": unique_triangles,
        "position_vertices_across_primitives": scene_position_vertices,
        "scene_instance_position_vertices": scene_position_vertices,
        "unique_mesh_position_vertices": unique_position_vertices,
        "materials": len(materials),
        "materials_referenced": len(used_materials),
        "material_names": material_names,
        "textures": len(textures),
        "images": len(images),
        "samplers": len(samplers),
        "estimated_vertex_attribute_bytes": vertex_bytes,
        "estimated_index_bytes": index_bytes,
        "estimated_geometry_bytes": sum(accessor_byte_estimate(doc, i) for i in vertex_accessors | index_accessors),
        "geometry_memory_basis": "unique decoded accessor payloads including morph targets; excludes engine overhead and staging copies",
        "rig_contract": rig_metrics(doc, active),
        **texture_metrics(doc, path),
    }


def policy_result(metrics: dict[str, Any], args: argparse.Namespace) -> dict[str, Any]:
    checks: list[dict[str, Any]] = []

    def check(name: str, ok: bool, actual: Any, limit: Any) -> None:
        checks.append({"name": name, "pass": bool(ok), "actual": actual, "limit": limit})

    check("triangle_cap", metrics["scene_instance_triangles"] <= args.max_triangles, metrics["scene_instance_triangles"], args.max_triangles)
    check("material_cap", metrics["materials_referenced"] <= args.max_materials, metrics["materials_referenced"], args.max_materials)
    check("texture_cap", metrics["textures"] <= args.max_textures, metrics["textures"], args.max_textures)
    check("mesh_references_valid", metrics["invalid_mesh_references"] == 0, metrics["invalid_mesh_references"], 0)
    check("scene_valid", not metrics["scene_errors"], metrics["scene_errors"], [])
    check("geometry_valid", not metrics["geometry_errors"], metrics["geometry_errors"], [])
    check("renderable_geometry", metrics["scene_instance_triangles"] > 0, metrics["scene_instance_triangles"], ">0")
    check("texture_dimensions_verified", not metrics["unresolved_images"], metrics["unresolved_images"], [])
    check("texture_references_valid", not metrics["texture_reference_errors"], metrics["texture_reference_errors"], [])
    dimension = max((max(i["width"], i["height"]) for i in metrics["image_dimensions"]), default=0)
    check("texture_dimension_cap", dimension <= args.max_texture_dimension, dimension, args.max_texture_dimension)
    texture_bytes = metrics["estimated_texture_rgba8_mip_bytes"]
    check("texture_memory_cap", texture_bytes is not None and texture_bytes <= args.max_texture_memory_mib * 1024 * 1024,
          texture_bytes, args.max_texture_memory_mib * 1024 * 1024)
    if args.require_rig:
        check("yardman_rig_contract", metrics["rig_contract"]["pass"], metrics["rig_contract"], "unique active nodes with wheel/spin parenting")
    return {"pass": all(c["pass"] for c in checks), "checks": checks}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("glb", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--max-triangles", type=int, default=120_000)
    parser.add_argument("--max-materials", type=int, default=16)
    parser.add_argument("--max-textures", type=int, default=16)
    parser.add_argument("--max-texture-dimension", type=int, default=4096)
    parser.add_argument("--max-texture-memory-mib", type=float, default=64)
    parser.add_argument("--require-rig", action="store_true")
    args = parser.parse_args()

    try:
        doc = load_glb(args.glb)
        metrics = collect_metrics(doc, args.glb)
        report = {
            "format_version": 2,
            "tool": "yardman_vehicle_glb_audit",
            "metrics": metrics,
            "policy": policy_result(metrics, args),
        }
    except Exception as exc:
        report = {"format_version": 2, "tool": "yardman_vehicle_glb_audit", "error": str(exc), "policy": {"pass": False}}

    text = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
    print(text, end="")
    return 0 if report.get("policy", {}).get("pass") else 1


if __name__ == "__main__":
    raise SystemExit(main())
