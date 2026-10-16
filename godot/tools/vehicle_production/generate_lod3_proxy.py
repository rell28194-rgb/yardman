#!/usr/bin/env python3
"""Generate a tiny original Yardman vehicle LOD3 GLB from dimensions only.

The proxy copies no source mesh or texture data. It preserves only broad vehicle
measurements and Yardman's wheel-rig node contract for cheap distant rendering.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import struct
from pathlib import Path


def _face_mesh(corners, faces):
    positions, normals, indices = [], [], []
    for corner_ids, normal in faces:
        base = len(positions)
        for corner_id in corner_ids:
            positions.append(corners[corner_id])
            normals.append(normal)
        indices += [base, base + 1, base + 2, base, base + 2, base + 3]
    return positions, normals, indices


def _frustum(width_bottom, width_top, y0, y1, z0, z1, ztop0, ztop1):
    wb, wt = width_bottom * 0.5, width_top * 0.5
    corners = [
        (-wb, y0, z0), (wb, y0, z0), (wb, y0, z1), (-wb, y0, z1),
        (-wt, y1, ztop0), (wt, y1, ztop0), (wt, y1, ztop1), (-wt, y1, ztop1),
    ]
    faces = [
        ((0, 1, 2, 3), (0, -1, 0)), ((4, 7, 6, 5), (0, 1, 0)),
        ((0, 4, 5, 1), (0, 0, -1)), ((3, 2, 6, 7), (0, 0, 1)),
        ((0, 3, 7, 4), (-1, 0, 0)), ((1, 5, 6, 2), (1, 0, 0)),
    ]
    return _face_mesh(corners, faces)


def _wheel(radius, width, segments=8):
    positions, normals, indices = [], [], []
    x0, x1 = -width * 0.5, width * 0.5
    for segment in range(segments):
        a = math.tau * segment / segments
        b = math.tau * (segment + 1) / segments
        y0, z0 = radius * math.cos(a), radius * math.sin(a)
        y1, z1 = radius * math.cos(b), radius * math.sin(b)
        mid = (a + b) * 0.5
        normal = (0, math.cos(mid), math.sin(mid))
        base = len(positions)
        positions += [(x0, y0, z0), (x1, y0, z0), (x1, y1, z1), (x0, y1, z1)]
        normals += [normal] * 4
        indices += [base, base + 1, base + 2, base, base + 2, base + 3]
    for x, nx, reverse in ((x0, -1, True), (x1, 1, False)):
        center = len(positions)
        positions.append((x, 0, 0))
        normals.append((nx, 0, 0))
        ring = []
        for segment in range(segments):
            angle = math.tau * segment / segments
            ring.append(len(positions))
            positions.append((x, radius * math.cos(angle), radius * math.sin(angle)))
            normals.append((nx, 0, 0))
        for segment in range(segments):
            a, b = ring[segment], ring[(segment + 1) % segments]
            indices += [center, b, a] if reverse else [center, a, b]
    return positions, normals, indices


def _floats(values):
    flat = [value for row in values for value in row]
    return struct.pack(f"<{len(flat)}f", *flat)


def _u16(values):
    return struct.pack(f"<{len(values)}H", *values)


def generate(output: Path, width: float, height: float, length: float, wheelbase: float, wheel_radius: float, paint):
    z0, z1 = -length * 0.5, length * 0.5
    shoulder = height * 0.54
    body = _frustum(width * 0.96, width, 0.0, shoulder, z0, z1, z0 + length * 0.03, z1 - length * 0.03)
    cabin = _frustum(width * 0.78, width * 0.60, shoulder, height, z0 + length * 0.24, z1 - length * 0.20, z0 + length * 0.34, z1 - length * 0.30)
    wheel = _wheel(wheel_radius, wheel_radius * 0.58)

    binary = bytearray()
    buffer_views, accessors = [], []

    def add_mesh(mesh):
        positions, normals, indices = mesh
        while len(binary) % 4:
            binary.append(0)
        pos_offset = len(binary)
        payload = _floats(positions)
        binary.extend(payload)
        buffer_views.append({"buffer": 0, "byteOffset": pos_offset, "byteLength": len(payload), "target": 34962})
        mins = [min(row[axis] for row in positions) for axis in range(3)]
        maxs = [max(row[axis] for row in positions) for axis in range(3)]
        accessors.append({"bufferView": len(buffer_views) - 1, "componentType": 5126, "count": len(positions), "type": "VEC3", "min": mins, "max": maxs})
        position_accessor = len(accessors) - 1

        while len(binary) % 4:
            binary.append(0)
        normal_offset = len(binary)
        payload = _floats(normals)
        binary.extend(payload)
        buffer_views.append({"buffer": 0, "byteOffset": normal_offset, "byteLength": len(payload), "target": 34962})
        accessors.append({"bufferView": len(buffer_views) - 1, "componentType": 5126, "count": len(normals), "type": "VEC3"})
        normal_accessor = len(accessors) - 1

        while len(binary) % 4:
            binary.append(0)
        index_offset = len(binary)
        payload = _u16(indices)
        binary.extend(payload)
        buffer_views.append({"buffer": 0, "byteOffset": index_offset, "byteLength": len(payload), "target": 34963})
        accessors.append({"bufferView": len(buffer_views) - 1, "componentType": 5123, "count": len(indices), "type": "SCALAR", "min": [min(indices)], "max": [max(indices)]})
        return position_accessor, normal_accessor, len(accessors) - 1

    body_accessors = add_mesh(body)
    cabin_accessors = add_mesh(cabin)
    wheel_accessors = add_mesh(wheel)
    materials = [
        {"name": "LOD3Paint", "pbrMetallicRoughness": {"baseColorFactor": paint, "metallicFactor": 0.45, "roughnessFactor": 0.38}},
        {"name": "LOD3Glass", "pbrMetallicRoughness": {"baseColorFactor": [0.04, 0.07, 0.09, 1], "metallicFactor": 0.0, "roughnessFactor": 0.2}},
        {"name": "LOD3Tyre", "pbrMetallicRoughness": {"baseColorFactor": [0.018, 0.018, 0.02, 1], "metallicFactor": 0.0, "roughnessFactor": 0.82}},
    ]
    meshes = []
    for name, refs, material in (("BodyLowerLOD3", body_accessors, 0), ("CabinLOD3", cabin_accessors, 1), ("WheelLOD3", wheel_accessors, 2)):
        meshes.append({"name": name, "primitives": [{"attributes": {"POSITION": refs[0], "NORMAL": refs[1]}, "indices": refs[2], "material": material}]})

    track = width * 0.84
    nodes = [
        {"name": "VehicleLOD3", "children": [1, 4, 6, 8, 10]},
        {"name": "BodyShell", "children": [2, 3]},
        {"name": "BodyLower", "mesh": 0},
        {"name": "Cabin", "mesh": 1},
    ]
    for name, x, z in (
        ("FrontWheelLeft", -track * 0.5, -wheelbase * 0.5),
        ("FrontWheelRight", track * 0.5, -wheelbase * 0.5),
        ("RearWheelLeft", -track * 0.5, wheelbase * 0.5),
        ("RearWheelRight", track * 0.5, wheelbase * 0.5),
    ):
        pivot_index = len(nodes)
        nodes.append({"name": name, "translation": [x, wheel_radius, z], "children": [pivot_index + 1]})
        nodes.append({"name": name + "Spin", "mesh": 2})

    document = {
        "asset": {"version": "2.0", "generator": "Yardman generate_lod3_proxy.py"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": nodes,
        "meshes": meshes,
        "materials": materials,
        "accessors": accessors,
        "bufferViews": buffer_views,
        "buffers": [{"byteLength": len(binary)}],
    }
    json_chunk = json.dumps(document, separators=(",", ":")).encode("utf-8")
    while len(json_chunk) % 4:
        json_chunk += b" "
    while len(binary) % 4:
        binary.append(0)
    total = 12 + 8 + len(json_chunk) + 8 + len(binary)
    glb = struct.pack("<III", 0x46546C67, 2, total) + struct.pack("<II", len(json_chunk), 0x4E4F534A) + json_chunk + struct.pack("<II", len(binary), 0x004E4942) + binary
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(glb)
    print(json.dumps({"output": str(output), "bytes": len(glb), "sha256": hashlib.sha256(glb).hexdigest()}, sort_keys=True))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("--width", type=float, required=True)
    parser.add_argument("--height", type=float, required=True)
    parser.add_argument("--length", type=float, required=True)
    parser.add_argument("--wheelbase", type=float, required=True)
    parser.add_argument("--wheel-radius", type=float, required=True)
    parser.add_argument("--paint", default="0.12,0.12,0.14")
    args = parser.parse_args()
    rgb = [float(value) for value in args.paint.split(",")]
    if len(rgb) != 3 or any(value < 0.0 or value > 1.0 for value in rgb):
        parser.error("--paint must be r,g,b with values from 0 to 1")
    generate(args.output, args.width, args.height, args.length, args.wheelbase, args.wheel_radius, rgb + [1])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
