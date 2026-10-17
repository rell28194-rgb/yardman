#!/usr/bin/env python3
"""Recover Mesh objects from Unity 2018.2 serialized files into glTF/GLB.

Yardman uses this for evidence-backed vehicle component recovery when the owner
source cache contains type-tree-disabled Unity serialized assets. The tool is
intentionally strict: unsupported mesh layouts fail instead of silently
producing malformed geometry.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import math
import struct
from pathlib import Path
from typing import Any

GLB_MAGIC = 0x46546C67
GLB_JSON = 0x4E4F534A
GLB_BIN = 0x004E4942
MESH_CLASS_ID = 43


def align4(value: int) -> int:
    return (value + 3) & ~3


def read_source(path: Path) -> bytes:
    raw = path.read_bytes()
    return gzip.decompress(raw) if path.suffix.lower() == ".gz" else raw


class Reader:
    def __init__(self, data: bytes, position: int = 0):
        self.data = data
        self.position = position

    def u8(self) -> int:
        value = self.data[self.position]
        self.position += 1
        return value

    def i16(self) -> int:
        value = struct.unpack_from("<h", self.data, self.position)[0]
        self.position += 2
        return value

    def i32(self) -> int:
        value = struct.unpack_from("<i", self.data, self.position)[0]
        self.position += 4
        return value

    def u32(self) -> int:
        value = struct.unpack_from("<I", self.data, self.position)[0]
        self.position += 4
        return value

    def i64(self) -> int:
        value = struct.unpack_from("<q", self.data, self.position)[0]
        self.position += 8
        return value

    def cstring(self) -> str:
        end = self.data.index(0, self.position)
        value = self.data[self.position:end].decode("utf-8", "replace")
        self.position = end + 1
        return value

    def aligned(self) -> None:
        self.position = align4(self.position)


def serialized_mesh_objects(raw: bytes) -> tuple[str, list[tuple[int, bytes]]]:
    if len(raw) < 20:
        raise ValueError("serialized file is too small")
    metadata_size, file_size, version, data_offset = struct.unpack_from(">IIII", raw, 0)
    if file_size != len(raw):
        raise ValueError("serialized file length does not match header")
    if version != 17:
        raise ValueError(f"expected Unity serialized-file version 17, got {version}")
    if data_offset >= len(raw):
        raise ValueError("invalid serialized-file data offset")

    reader = Reader(raw, 20)
    unity_version = reader.cstring()
    if not unity_version.startswith("2018.2."):
        raise ValueError(f"expected Unity 2018.2 source, got {unity_version}")
    reader.i32()  # target platform
    type_tree_enabled = reader.u8()
    if type_tree_enabled:
        raise ValueError("type-tree-enabled files are not supported by this strict extractor")

    type_count = reader.i32()
    class_ids: list[int] = []
    for _ in range(type_count):
        class_id = reader.i32()
        reader.u8()  # stripped
        reader.i16()  # script type index
        if class_id == 114:
            reader.position += 16  # script id
        reader.position += 16  # old type hash
        class_ids.append(class_id)

    object_count = reader.i32()
    objects: list[tuple[int, int, int, int]] = []
    for _ in range(object_count):
        reader.aligned()
        path_id = reader.i64()
        byte_start = reader.u32()
        byte_size = reader.u32()
        type_index = reader.i32()
        if not (0 <= type_index < len(class_ids)):
            raise ValueError("invalid serialized object type index")
        objects.append((path_id, byte_start, byte_size, class_ids[type_index]))

    metadata_end = 20 + metadata_size
    if reader.position > metadata_end:
        raise ValueError("object table extends beyond serialized metadata")

    meshes: list[tuple[int, bytes]] = []
    for path_id, byte_start, byte_size, class_id in objects:
        if class_id != MESH_CLASS_ID:
            continue
        absolute = data_offset + byte_start
        end = absolute + byte_size
        if end > len(raw):
            raise ValueError("mesh object extends beyond serialized file")
        meshes.append((path_id, raw[absolute:end]))
    if not meshes:
        raise ValueError("serialized file contains no Mesh objects")
    return unity_version, meshes


def read_aligned_string(data: bytes, offset: int) -> tuple[str, int]:
    length = struct.unpack_from("<i", data, offset)[0]
    offset += 4
    if length < 0 or offset + length > len(data):
        raise ValueError("invalid aligned string")
    value = data[offset:offset + length].decode("utf-8", "replace")
    return value, align4(offset + length)


def parse_mesh(path_id: int, data: bytes) -> dict[str, Any]:
    name, offset = read_aligned_string(data, 0)
    submesh_count = struct.unpack_from("<i", data, offset)[0]
    offset += 4
    if submesh_count <= 0:
        raise ValueError(f"{name}: mesh has no submeshes")

    submeshes: list[dict[str, Any]] = []
    for _ in range(submesh_count):
        if offset + 48 > len(data):
            raise ValueError(f"{name}: truncated SubMesh")
        first_byte, index_count, topology, base_vertex, first_vertex, vertex_count = struct.unpack_from(
            "<IIIIII", data, offset
        )
        offset += 24
        center = struct.unpack_from("<fff", data, offset)
        extent = struct.unpack_from("<fff", data, offset + 12)
        offset += 24
        if topology != 0:
            raise ValueError(f"{name}: only triangle-list submeshes are supported")
        submeshes.append(
            {
                "first_byte": first_byte,
                "index_count": index_count,
                "base_vertex": base_vertex,
                "first_vertex": first_vertex,
                "vertex_count": vertex_count,
                "center": center,
                "extent": extent,
            }
        )

    # BlendShapeData: vertices, shapes, channels, full weights. Vehicle wheel
    # meshes in the recovery pool should not carry blend shapes.
    for label in ("blend_vertices", "blend_shapes", "blend_channels", "blend_weights"):
        count = struct.unpack_from("<i", data, offset)[0]
        offset += 4
        if count != 0:
            raise ValueError(f"{name}: unsupported non-empty {label}")

    bind_pose_count = struct.unpack_from("<i", data, offset)[0]
    offset += 4 + bind_pose_count * 64
    bone_hash_count = struct.unpack_from("<i", data, offset)[0]
    offset += 4 + bone_hash_count * 4
    offset += 4  # root bone name hash
    if offset + 4 > len(data):
        raise ValueError(f"{name}: truncated mesh flags")
    mesh_compression, is_readable, keep_vertices, keep_indices = struct.unpack_from("<BBBB", data, offset)
    offset += 4
    if mesh_compression != 0:
        raise ValueError(f"{name}: compressed meshes are not supported")

    index_format = struct.unpack_from("<i", data, offset)[0]
    offset += 4
    if index_format not in (0, 1):
        raise ValueError(f"{name}: unsupported index format {index_format}")
    index_buffer_size = struct.unpack_from("<i", data, offset)[0]
    offset += 4
    index_buffer = data[offset:offset + index_buffer_size]
    if len(index_buffer) != index_buffer_size:
        raise ValueError(f"{name}: truncated index buffer")
    offset = align4(offset + index_buffer_size)

    vertex_count = struct.unpack_from("<I", data, offset)[0]
    offset += 4
    channel_count = struct.unpack_from("<i", data, offset)[0]
    offset += 4
    if channel_count <= 0:
        raise ValueError(f"{name}: mesh has no vertex channels")
    channels: list[tuple[int, int, int, int]] = []
    for _ in range(channel_count):
        channels.append(struct.unpack_from("<BBBB", data, offset))
        offset += 4

    data_size = struct.unpack_from("<i", data, offset)[0]
    offset += 4
    vertex_data = data[offset:offset + data_size]
    if len(vertex_data) != data_size:
        raise ValueError(f"{name}: truncated vertex data")

    active = [(i, *channel) for i, channel in enumerate(channels) if channel[3] > 0]
    if not active or active[0][0] != 0:
        raise ValueError(f"{name}: POSITION channel is missing")
    if any(stream != 0 for _, stream, _, _, _ in active):
        raise ValueError(f"{name}: multi-stream vertex data is not supported")
    if any(fmt != 0 for _, _, _, fmt, _ in active):
        raise ValueError(f"{name}: only Float32 vertex channels are supported")
    stride = max(channel_offset + dimension * 4 for _, _, channel_offset, _, dimension in active)
    if stride * vertex_count != data_size:
        raise ValueError(f"{name}: unexpected vertex stride/data size")

    def channel_values(channel_index: int, expected_dimension: int) -> list[tuple[float, ...]] | None:
        if channel_index >= len(channels):
            return None
        stream, channel_offset, fmt, dimension = channels[channel_index]
        if dimension == 0:
            return None
        if stream != 0 or fmt != 0 or dimension < expected_dimension:
            raise ValueError(f"{name}: unsupported channel {channel_index}")
        fmt_string = "<" + "f" * expected_dimension
        return [
            struct.unpack_from(fmt_string, vertex_data, index * stride + channel_offset)
            for index in range(vertex_count)
        ]

    positions = channel_values(0, 3)
    normals = channel_values(1, 3)
    uv0 = channel_values(4, 2)
    uv1 = channel_values(6, 2)
    if positions is None:
        raise ValueError(f"{name}: no positions")

    index_size = 2 if index_format == 0 else 4
    component_type = 5123 if index_size == 2 else 5125
    unpack_code = "H" if index_size == 2 else "I"
    primitive_indices: list[list[int]] = []
    for submesh in submeshes:
        first_byte = int(submesh["first_byte"])
        count = int(submesh["index_count"])
        end = first_byte + count * index_size
        if end > len(index_buffer):
            raise ValueError(f"{name}: submesh index range exceeds index buffer")
        indices = list(struct.unpack_from("<" + unpack_code * count, index_buffer, first_byte))
        base_vertex = int(submesh["base_vertex"])
        if base_vertex:
            indices = [index + base_vertex for index in indices]
        if any(index >= vertex_count for index in indices):
            raise ValueError(f"{name}: index references a missing vertex")
        primitive_indices.append(indices)

    return {
        "path_id": path_id,
        "name": name,
        "positions": positions,
        "normals": normals,
        "uv0": uv0,
        "uv1": uv1,
        "indices": primitive_indices,
        "index_component_type": component_type,
        "source_flags": {
            "is_readable": bool(is_readable),
            "keep_vertices": bool(keep_vertices),
            "keep_indices": bool(keep_indices),
        },
    }


def pad4(data: bytes, byte: bytes = b"\x00") -> bytes:
    return data + byte * ((-len(data)) % 4)


def build_glb(meshes: list[dict[str, Any]], source_sha256: str, source_name: str) -> bytes:
    document: dict[str, Any] = {
        "asset": {"version": "2.0", "generator": "Yardman Unity 2018 exact mesh recovery"},
        "scene": 0,
        "scenes": [{"nodes": []}],
        "nodes": [],
        "meshes": [],
        "buffers": [{"byteLength": 0}],
        "bufferViews": [],
        "accessors": [],
        "extras": {"source_sha256": source_sha256, "source_name": source_name},
    }
    binary = bytearray()

    def append_view(payload: bytes, target: int | None = None, stride: int | None = None) -> int:
        nonlocal binary
        while len(binary) % 4:
            binary.append(0)
        start = len(binary)
        binary.extend(payload)
        view: dict[str, Any] = {"buffer": 0, "byteOffset": start, "byteLength": len(payload)}
        if target is not None:
            view["target"] = target
        if stride is not None:
            view["byteStride"] = stride
        document["bufferViews"].append(view)
        return len(document["bufferViews"]) - 1

    def add_accessor(view: int, component_type: int, count: int, kind: str, minimum=None, maximum=None) -> int:
        accessor: dict[str, Any] = {
            "bufferView": view,
            "componentType": component_type,
            "count": count,
            "type": kind,
        }
        if minimum is not None:
            accessor["min"] = minimum
        if maximum is not None:
            accessor["max"] = maximum
        document["accessors"].append(accessor)
        return len(document["accessors"]) - 1

    for mesh in meshes:
        positions = [(x, y, -z) for x, y, z in mesh["positions"]]
        normals = None if mesh["normals"] is None else [(x, y, -z) for x, y, z in mesh["normals"]]
        vertex_payload = bytearray()
        for index, position in enumerate(positions):
            vertex_payload.extend(struct.pack("<fff", *position))
            if normals is not None:
                vertex_payload.extend(struct.pack("<fff", *normals[index]))
            if mesh["uv0"] is not None:
                vertex_payload.extend(struct.pack("<ff", *mesh["uv0"][index]))
        stride = 12 + (12 if normals is not None else 0) + (8 if mesh["uv0"] is not None else 0)
        vertex_view = append_view(bytes(vertex_payload), target=34962, stride=stride)
        mins = [min(value[axis] for value in positions) for axis in range(3)]
        maxs = [max(value[axis] for value in positions) for axis in range(3)]
        position_accessor = add_accessor(vertex_view, 5126, len(positions), "VEC3", mins, maxs)
        attributes: dict[str, int] = {"POSITION": position_accessor}
        byte_offset = 12
        if normals is not None:
            accessor = {
                "bufferView": vertex_view,
                "byteOffset": byte_offset,
                "componentType": 5126,
                "count": len(positions),
                "type": "VEC3",
            }
            document["accessors"].append(accessor)
            attributes["NORMAL"] = len(document["accessors"]) - 1
            byte_offset += 12
        if mesh["uv0"] is not None:
            accessor = {
                "bufferView": vertex_view,
                "byteOffset": byte_offset,
                "componentType": 5126,
                "count": len(positions),
                "type": "VEC2",
            }
            document["accessors"].append(accessor)
            attributes["TEXCOORD_0"] = len(document["accessors"]) - 1

        primitives: list[dict[str, Any]] = []
        for source_indices in mesh["indices"]:
            indices: list[int] = []
            for index in range(0, len(source_indices), 3):
                a, b, c = source_indices[index:index + 3]
                indices.extend((a, c, b))  # Unity LH -> glTF RH after Z flip.
            component_type = mesh["index_component_type"]
            pack_code = "H" if component_type == 5123 else "I"
            index_payload = struct.pack("<" + pack_code * len(indices), *indices)
            index_view = append_view(index_payload, target=34963)
            index_accessor = add_accessor(index_view, component_type, len(indices), "SCALAR", [min(indices)], [max(indices)])
            primitives.append({"attributes": dict(attributes), "indices": index_accessor, "mode": 4})

        document["meshes"].append(
            {
                "name": mesh["name"],
                "primitives": primitives,
                "extras": {"source_path_id": mesh["path_id"]},
            }
        )
        node_index = len(document["nodes"])
        document["nodes"].append({"name": mesh["name"], "mesh": len(document["meshes"]) - 1})
        document["scenes"][0]["nodes"].append(node_index)

    document["buffers"][0]["byteLength"] = len(binary)
    json_chunk = pad4(json.dumps(document, separators=(",", ":")).encode("utf-8"), b" ")
    bin_chunk = pad4(bytes(binary), b"\x00")
    total_length = 12 + 8 + len(json_chunk) + 8 + len(bin_chunk)
    return b"".join(
        [
            struct.pack("<III", GLB_MAGIC, 2, total_length),
            struct.pack("<II", len(json_chunk), GLB_JSON),
            json_chunk,
            struct.pack("<II", len(bin_chunk), GLB_BIN),
            bin_chunk,
        ]
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--path-id", action="append", type=int, default=[])
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()

    compressed = args.source.read_bytes()
    raw = read_source(args.source)
    unity_version, objects = serialized_mesh_objects(raw)
    wanted = set(args.path_id)
    meshes = [parse_mesh(path_id, data) for path_id, data in objects if not wanted or path_id in wanted]
    if wanted and wanted != {mesh["path_id"] for mesh in meshes}:
        raise SystemExit("one or more requested path IDs were not found")

    source_sha256 = hashlib.sha256(compressed).hexdigest()
    output = build_glb(meshes, source_sha256, args.source.name)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(output)

    report = {
        "format_version": 1,
        "tool": "yardman_unity2018_mesh_recovery",
        "unity_version": unity_version,
        "source_file": args.source.name,
        "source_bytes": len(compressed),
        "source_sha256": source_sha256,
        "output_file": args.output.name,
        "output_bytes": len(output),
        "output_sha256": hashlib.sha256(output).hexdigest(),
        "meshes": [
            {
                "name": mesh["name"],
                "path_id": mesh["path_id"],
                "vertices": len(mesh["positions"]),
                "triangles": sum(len(indices) // 3 for indices in mesh["indices"]),
                "submeshes": len(mesh["indices"]),
            }
            for mesh in meshes
        ],
    }
    text = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(text, encoding="utf-8")
    print(text, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
