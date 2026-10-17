#!/usr/bin/env python3
"""Audit a recovered Yardman vehicle GLB before game promotion.

This is intentionally stricter than the distant-LOD budget audit. It validates
production-rig hierarchy, metre-scale geometry, wheel/axle placement and basic
fitment ratios without importing private media into the public repository.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import struct
from pathlib import Path
from typing import Any

GLB_MAGIC = 0x46546C67
JSON_CHUNK = 0x4E4F534A
RIG_NODES = (
    "BodyShell",
    "FrontWheelLeft",
    "FrontWheelRight",
    "RearWheelLeft",
    "RearWheelRight",
    "FrontWheelLeftSpin",
    "FrontWheelRightSpin",
    "RearWheelLeftSpin",
    "RearWheelRightSpin",
)
WHEEL_PIVOTS = (
    "FrontWheelLeft",
    "FrontWheelRight",
    "RearWheelLeft",
    "RearWheelRight",
)
WHEEL_SPINS = (
    "FrontWheelLeftSpin",
    "FrontWheelRightSpin",
    "RearWheelLeftSpin",
    "RearWheelRightSpin",
)


def load_glb(path: Path) -> tuple[bytes, dict[str, Any]]:
    raw = path.read_bytes()
    if len(raw) < 20:
        raise ValueError("file too small for GLB")
    magic, version, declared = struct.unpack_from("<III", raw, 0)
    if magic != GLB_MAGIC or version != 2 or declared != len(raw):
        raise ValueError("invalid glTF 2.0 binary header")
    offset = 12
    document: dict[str, Any] | None = None
    while offset + 8 <= len(raw):
        length, chunk_type = struct.unpack_from("<II", raw, offset)
        offset += 8
        end = offset + length
        if end > len(raw):
            raise ValueError("GLB chunk extends past EOF")
        if chunk_type == JSON_CHUNK:
            document = json.loads(raw[offset:end].decode("utf-8").rstrip(" \t\r\n\x00"))
            break
        offset = end
    if not isinstance(document, dict):
        raise ValueError("GLB has no JSON chunk")
    return raw, document


def identity_matrix() -> list[float]:
    return [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0]


def matrix_multiply(a: list[float], b: list[float]) -> list[float]:
    result = [0.0] * 16
    for column in range(4):
        for row in range(4):
            result[column * 4 + row] = sum(
                a[k * 4 + row] * b[column * 4 + k] for k in range(4)
            )
    return result


def node_matrix(node: dict[str, Any]) -> list[float]:
    matrix = node.get("matrix")
    if isinstance(matrix, list) and len(matrix) == 16:
        return [float(value) for value in matrix]

    translation = [float(value) for value in node.get("translation", [0.0, 0.0, 0.0])]
    scale = [float(value) for value in node.get("scale", [1.0, 1.0, 1.0])]
    x, y, z, w = [float(value) for value in node.get("rotation", [0.0, 0.0, 0.0, 1.0])]
    xx, yy, zz = x * x, y * y, z * z
    xy, xz, yz = x * y, x * z, y * z
    wx, wy, wz = w * x, w * y, w * z
    return [
        (1 - 2 * (yy + zz)) * scale[0],
        (2 * (xy + wz)) * scale[0],
        (2 * (xz - wy)) * scale[0],
        0.0,
        (2 * (xy - wz)) * scale[1],
        (1 - 2 * (xx + zz)) * scale[1],
        (2 * (yz + wx)) * scale[1],
        0.0,
        (2 * (xz + wy)) * scale[2],
        (2 * (yz - wx)) * scale[2],
        (1 - 2 * (xx + yy)) * scale[2],
        0.0,
        translation[0],
        translation[1],
        translation[2],
        1.0,
    ]


def transform_point(matrix: list[float], point: list[float] | tuple[float, float, float]) -> tuple[float, float, float]:
    x, y, z = point
    return (
        matrix[0] * x + matrix[4] * y + matrix[8] * z + matrix[12],
        matrix[1] * x + matrix[5] * y + matrix[9] * z + matrix[13],
        matrix[2] * x + matrix[6] * y + matrix[10] * z + matrix[14],
    )


def box_corners(low: list[float], high: list[float]) -> list[tuple[float, float, float]]:
    return [
        (x, y, z)
        for x in (low[0], high[0])
        for y in (low[1], high[1])
        for z in (low[2], high[2])
    ]


def extend_bounds(
    bounds: list[list[float]] | None, point: tuple[float, float, float]
) -> list[list[float]]:
    if bounds is None:
        return [list(point), list(point)]
    for axis in range(3):
        bounds[0][axis] = min(bounds[0][axis], point[axis])
        bounds[1][axis] = max(bounds[1][axis], point[axis])
    return bounds


def audit(path: Path, identity: str) -> dict[str, Any]:
    raw, document = load_glb(path)
    nodes = document.get("nodes", [])
    meshes = document.get("meshes", [])
    accessors = document.get("accessors", [])

    indices: dict[str, list[int]] = {}
    parents: dict[int, int] = {}
    for index, node in enumerate(nodes):
        indices.setdefault(str(node.get("name", "")), []).append(index)
        for child in node.get("children", []):
            parents[int(child)] = index

    global_matrices: dict[int, list[float]] = {}

    def global_matrix(index: int) -> list[float]:
        if index in global_matrices:
            return global_matrices[index]
        local = node_matrix(nodes[index])
        parent = parents.get(index)
        result = matrix_multiply(global_matrix(parent), local) if parent is not None else local
        global_matrices[index] = result
        return result

    def is_ancestor(ancestor: int, node: int) -> bool:
        parent = parents.get(node)
        while parent is not None:
            if parent == ancestor:
                return True
            parent = parents.get(parent)
        return False

    def mesh_bounds(root: int | None = None) -> tuple[list[list[float]] | None, int]:
        bounds: list[list[float]] | None = None
        incomplete = 0
        if root is None:
            pairs = [(index, global_matrix(index)) for index in range(len(nodes))]
        else:
            pairs: list[tuple[int, list[float]]] = []

            def collect(index: int, matrix: list[float]) -> None:
                pairs.append((index, matrix))
                for child in nodes[index].get("children", []):
                    collect(int(child), matrix_multiply(matrix, node_matrix(nodes[int(child)])))

            collect(root, identity_matrix())

        for node_index, matrix in pairs:
            mesh_index = nodes[node_index].get("mesh")
            if not isinstance(mesh_index, int) or not (0 <= mesh_index < len(meshes)):
                continue
            for primitive in meshes[mesh_index].get("primitives", []):
                position_index = (primitive.get("attributes") or {}).get("POSITION")
                if not isinstance(position_index, int) or not (0 <= position_index < len(accessors)):
                    incomplete += 1
                    continue
                accessor = accessors[position_index]
                low = accessor.get("min")
                high = accessor.get("max")
                if not (
                    isinstance(low, list)
                    and isinstance(high, list)
                    and len(low) >= 3
                    and len(high) >= 3
                ):
                    incomplete += 1
                    continue
                for point in box_corners(low, high):
                    bounds = extend_bounds(bounds, transform_point(matrix, point))
        return bounds, incomplete

    def bounds_size(bounds: list[list[float]] | None) -> list[float]:
        if bounds is None:
            return [0.0, 0.0, 0.0]
        return [bounds[1][axis] - bounds[0][axis] for axis in range(3)]

    missing_or_duplicate = [name for name in RIG_NODES if len(indices.get(name, [])) != 1]
    rig_unique = not missing_or_duplicate

    spin_parented = True
    for pivot, spin in zip(WHEEL_PIVOTS, WHEEL_SPINS):
        if len(indices.get(pivot, [])) != 1 or len(indices.get(spin, [])) != 1:
            spin_parented = False
            continue
        spin_parented &= parents.get(indices[spin][0]) == indices[pivot][0]

    hierarchy_independent = len(indices.get("BodyShell", [])) == 1
    if hierarchy_independent:
        body_index = indices["BodyShell"][0]
        for pivot in WHEEL_PIVOTS:
            if len(indices.get(pivot, [])) != 1:
                hierarchy_independent = False
                break
            pivot_index = indices[pivot][0]
            if is_ancestor(body_index, pivot_index) or is_ancestor(pivot_index, body_index):
                hierarchy_independent = False
                break

    wheel_positions: dict[str, list[float]] = {}
    wheelbase = front_track = rear_track = 0.0
    axle_alignment = False
    if all(len(indices.get(name, [])) == 1 for name in WHEEL_PIVOTS):
        for name in WHEEL_PIVOTS:
            matrix = global_matrix(indices[name][0])
            wheel_positions[name] = [matrix[12], matrix[13], matrix[14]]
        front_left, front_right, rear_left, rear_right = [wheel_positions[name] for name in WHEEL_PIVOTS]
        wheelbase = ((rear_left[2] + rear_right[2]) - (front_left[2] + front_right[2])) * 0.5
        front_track = front_right[0] - front_left[0]
        rear_track = rear_right[0] - rear_left[0]
        axle_alignment = (
            1.8 <= wheelbase <= 4.5
            and 1.0 <= front_track <= 2.8
            and 1.0 <= rear_track <= 2.8
            and abs(front_left[2] - front_right[2]) < 0.15
            and abs(rear_left[2] - rear_right[2]) < 0.15
            and front_left[0] < 0.0 < front_right[0]
            and rear_left[0] < 0.0 < rear_right[0]
        )

    wheel_geometry: dict[str, dict[str, Any]] = {}
    wheel_geometry_pass = True
    for spin in WHEEL_SPINS:
        if len(indices.get(spin, [])) != 1:
            wheel_geometry_pass = False
            continue
        bounds, incomplete = mesh_bounds(indices[spin][0])
        size = bounds_size(bounds)
        radius = max(size[1], size[2]) * 0.5
        width = size[0]
        passed = bounds is not None and incomplete == 0 and width >= 0.02 and 0.20 <= radius <= 0.60
        wheel_geometry[spin] = {
            "size_m": [round(value, 6) for value in size],
            "radius_m": round(radius, 6),
            "width_m": round(width, 6),
            "pass": passed,
        }
        wheel_geometry_pass &= passed

    bounds, incomplete_bounds = mesh_bounds()
    size = bounds_size(bounds)
    metre_bounds = (
        bounds is not None
        and incomplete_bounds == 0
        and 1.0 <= size[0] <= 4.0
        and 0.5 <= size[1] <= 3.5
        and 2.0 <= size[2] <= 8.0
    )
    front_track_body_ratio = front_track / size[0] if size[0] > 0.0 else 0.0
    rear_track_body_ratio = rear_track / size[0] if size[0] > 0.0 else 0.0
    wheelbase_length_ratio = wheelbase / size[2] if size[2] > 0.0 else 0.0

    quality_warnings: list[str] = []
    if not (0.68 <= front_track_body_ratio <= 0.95) or not (0.68 <= rear_track_body_ratio <= 0.95):
        quality_warnings.append("suspicious_track_to_body_ratio")
    if not (0.48 <= wheelbase_length_ratio <= 0.68):
        quality_warnings.append("suspicious_wheelbase_to_length_ratio")

    triangles = 0
    used_materials: set[int] = set()
    mesh_instances = 0
    for node in nodes:
        mesh_index = node.get("mesh")
        if not isinstance(mesh_index, int) or not (0 <= mesh_index < len(meshes)):
            continue
        mesh_instances += 1
        for primitive in meshes[mesh_index].get("primitives", []):
            index_accessor = primitive.get("indices")
            position_accessor = (primitive.get("attributes") or {}).get("POSITION")
            accessor: dict[str, Any] = {}
            if isinstance(index_accessor, int) and 0 <= index_accessor < len(accessors):
                accessor = accessors[index_accessor]
            elif isinstance(position_accessor, int) and 0 <= position_accessor < len(accessors):
                accessor = accessors[position_accessor]
            count = int(accessor.get("count", 0))
            mode = int(primitive.get("mode", 4))
            if mode == 4:
                triangles += count // 3
            elif mode in (5, 6):
                triangles += max(0, count - 2)
            if isinstance(primitive.get("material"), int):
                used_materials.add(int(primitive["material"]))

    lowered_names = [str(node.get("name", "")).lower() for node in nodes]
    interior_evidence = any(
        any(keyword in name for keyword in ("interior", "driverwheel", "dashboard", "seat", "cabin"))
        for name in lowered_names
    )

    contract_pass = (
        rig_unique
        and spin_parented
        and hierarchy_independent
        and axle_alignment
        and wheel_geometry_pass
        and metre_bounds
    )
    return {
        "format_version": 1,
        "tool": "yardman_vehicle_candidate_audit",
        "identity": identity or path.parent.name,
        "file": path.name,
        "bytes": len(raw),
        "sha256": hashlib.sha256(raw).hexdigest(),
        "metrics": {
            "nodes": len(nodes),
            "mesh_instances": mesh_instances,
            "triangles": triangles,
            "materials_referenced": len(used_materials),
            "textures": len(document.get("textures", [])),
            "images": len(document.get("images", [])),
            "interior_evidence": interior_evidence,
            "bounds_m": [round(value, 6) for value in size],
            "bounds_complete": incomplete_bounds == 0,
            "wheelbase_m": round(wheelbase, 6),
            "front_track_m": round(front_track, 6),
            "rear_track_m": round(rear_track, 6),
            "front_track_body_ratio": round(front_track_body_ratio, 6),
            "rear_track_body_ratio": round(rear_track_body_ratio, 6),
            "wheelbase_length_ratio": round(wheelbase_length_ratio, 6),
            "wheel_pivots": wheel_positions,
            "wheel_geometry": wheel_geometry,
        },
        "quality": {
            "ready_for_visual_grade": contract_pass and not quality_warnings,
            "warnings": quality_warnings,
        },
        "contract": {
            "rig_nodes_unique": rig_unique,
            "missing_or_duplicate_nodes": missing_or_duplicate,
            "spin_parented_to_pivot": spin_parented,
            "body_wheel_hierarchy_independent": hierarchy_independent,
            "axle_alignment": axle_alignment,
            "wheel_geometry": wheel_geometry_pass,
            "metre_bounds": metre_bounds,
            "pass": contract_pass,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("glb", type=Path)
    parser.add_argument("--identity", default="")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    try:
        report = audit(args.glb, args.identity)
    except Exception as exc:
        report = {
            "format_version": 1,
            "tool": "yardman_vehicle_candidate_audit",
            "file": args.glb.name,
            "identity": args.identity or args.glb.parent.name,
            "error": str(exc),
            "contract": {"pass": False},
        }

    text = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
    print(text, end="")
    return 0 if bool(report.get("contract", {}).get("pass")) else 1


if __name__ == "__main__":
    raise SystemExit(main())
