#!/usr/bin/env python3
"""Build private Toyota Chaser V LOD1/LOD2 assets from the verified road_car GLB.

This tool contains no private vehicle media. It verifies the exact source hash,
then compacts selected source geometry/material dependencies into intentional
normal-gameplay and medium-distance tiers. Output media remains private.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import struct
from pathlib import Path

SOURCE_SHA256 = "86556496ce2eeaa29c57c7fcc16bec11c230179485609e08b160313594cf3f03"
JSON_CHUNK = 0x4E4F534A
BIN_CHUNK = 0x004E4942
GLB_MAGIC = 0x46546C67

LOD1_NODES = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 13, 14, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30}
LOD2_NODES = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 13, 14, 19, 20, 21, 22, 27, 28, 29, 30}


def load_glb(path: Path):
    raw = path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != SOURCE_SHA256:
        raise ValueError("source road_car.glb hash does not match verified Toyota Chaser V source")
    magic, version, declared = struct.unpack_from("<III", raw, 0)
    if magic != GLB_MAGIC or version != 2 or declared != len(raw):
        raise ValueError("invalid glTF 2.0 binary container")
    offset = 12
    document = None
    binary = b""
    while offset + 8 <= len(raw):
        length, chunk_type = struct.unpack_from("<II", raw, offset)
        offset += 8
        payload = raw[offset:offset + length]
        offset += length
        if chunk_type == JSON_CHUNK:
            document = json.loads(payload.decode("utf-8").rstrip(" \t\r\n\x00"))
        elif chunk_type == BIN_CHUNK:
            binary = payload
    if not isinstance(document, dict):
        raise ValueError("missing GLB JSON chunk")
    return document, binary


def mutate_material(material_id: int, material: dict) -> dict:
    if material_id == 10:  # GenericS: 1024x1024 source texture is wasteful outside LOD0.
        pbr = material.setdefault("pbrMetallicRoughness", {})
        pbr.pop("baseColorTexture", None)
        pbr["baseColorFactor"] = [0.45, 0.47, 0.50, 1.0]
        pbr["metallicFactor"] = 0.45
        pbr["roughnessFactor"] = 0.36
        material["name"] = "ToyotaChaserV - GenericS LOD Flat"
    return material


def collect_texture_indices(value, output: set[int]):
    if isinstance(value, dict):
        for key, item in value.items():
            if key.endswith("Texture") and isinstance(item, dict) and isinstance(item.get("index"), int):
                output.add(item["index"])
            collect_texture_indices(item, output)
    elif isinstance(value, list):
        for item in value:
            collect_texture_indices(item, output)


def remap_texture_indices(value, texture_map: dict[int, int]):
    if isinstance(value, dict):
        for key, item in value.items():
            if key.endswith("Texture") and isinstance(item, dict) and isinstance(item.get("index"), int):
                item["index"] = texture_map[item["index"]]
            remap_texture_indices(item, texture_map)
    elif isinstance(value, list):
        for item in value:
            remap_texture_indices(item, texture_map)


def build_subset(document: dict, binary: bytes, selected_nodes: set[int], excluded_primitives: dict[int, set[int]], output: Path):
    selected_mesh_ids = []
    for node_id in sorted(selected_nodes):
        mesh_id = document["nodes"][node_id].get("mesh")
        if isinstance(mesh_id, int) and mesh_id not in selected_mesh_ids:
            selected_mesh_ids.append(mesh_id)

    used_accessors: set[int] = set()
    used_materials: set[int] = set()
    new_meshes = []
    mesh_map = {}
    for old_mesh_id in selected_mesh_ids:
        old_mesh = document["meshes"][old_mesh_id]
        drop = excluded_primitives.get(old_mesh_id, set())
        primitives = []
        for primitive_id, primitive in enumerate(old_mesh.get("primitives", [])):
            if primitive_id in drop:
                continue
            item = copy.deepcopy(primitive)
            used_accessors.update(item.get("attributes", {}).values())
            if isinstance(item.get("indices"), int):
                used_accessors.add(item["indices"])
            if isinstance(item.get("material"), int):
                used_materials.add(item["material"])
            for target in item.get("targets", []):
                used_accessors.update(target.values())
            primitives.append(item)
        if primitives:
            mesh_map[old_mesh_id] = len(new_meshes)
            mesh = copy.deepcopy(old_mesh)
            mesh["primitives"] = primitives
            new_meshes.append(mesh)

    materials = {material_id: mutate_material(material_id, copy.deepcopy(document["materials"][material_id])) for material_id in sorted(used_materials)}
    used_textures: set[int] = set()
    for material in materials.values():
        collect_texture_indices(material, used_textures)

    used_images: set[int] = set()
    used_samplers: set[int] = set()
    for texture_id in sorted(used_textures):
        texture = document["textures"][texture_id]
        if isinstance(texture.get("source"), int):
            used_images.add(texture["source"])
        if isinstance(texture.get("sampler"), int):
            used_samplers.add(texture["sampler"])

    used_views: set[int] = set()
    for accessor_id in used_accessors:
        accessor = document["accessors"][accessor_id]
        if isinstance(accessor.get("bufferView"), int):
            used_views.add(accessor["bufferView"])
        sparse = accessor.get("sparse", {})
        for key in ("indices", "values"):
            if isinstance(sparse.get(key, {}).get("bufferView"), int):
                used_views.add(sparse[key]["bufferView"])
    for image_id in used_images:
        image = document["images"][image_id]
        if isinstance(image.get("bufferView"), int):
            used_views.add(image["bufferView"])

    packed = bytearray()
    view_map = {}
    new_views = []
    for old_view_id in sorted(used_views):
        old_view = document["bufferViews"][old_view_id]
        while len(packed) % 4:
            packed.append(0)
        start = old_view.get("byteOffset", 0)
        length = old_view["byteLength"]
        new_view = copy.deepcopy(old_view)
        new_view["buffer"] = 0
        new_view["byteOffset"] = len(packed)
        packed.extend(binary[start:start + length])
        view_map[old_view_id] = len(new_views)
        new_views.append(new_view)

    accessor_map = {}
    new_accessors = []
    for old_accessor_id in sorted(used_accessors):
        accessor = copy.deepcopy(document["accessors"][old_accessor_id])
        if isinstance(accessor.get("bufferView"), int):
            accessor["bufferView"] = view_map[accessor["bufferView"]]
        sparse = accessor.get("sparse", {})
        for key in ("indices", "values"):
            if isinstance(sparse.get(key, {}).get("bufferView"), int):
                sparse[key]["bufferView"] = view_map[sparse[key]["bufferView"]]
        accessor_map[old_accessor_id] = len(new_accessors)
        new_accessors.append(accessor)

    material_map = {old: new for new, old in enumerate(sorted(materials))}
    texture_map = {old: new for new, old in enumerate(sorted(used_textures))}
    image_map = {old: new for new, old in enumerate(sorted(used_images))}
    sampler_map = {old: new for new, old in enumerate(sorted(used_samplers))}

    new_materials = []
    for material_id in sorted(materials):
        material = materials[material_id]
        remap_texture_indices(material, texture_map)
        new_materials.append(material)

    new_textures = []
    for texture_id in sorted(used_textures):
        texture = copy.deepcopy(document["textures"][texture_id])
        if isinstance(texture.get("source"), int):
            texture["source"] = image_map[texture["source"]]
        if isinstance(texture.get("sampler"), int):
            texture["sampler"] = sampler_map[texture["sampler"]]
        new_textures.append(texture)

    new_images = []
    for image_id in sorted(used_images):
        image = copy.deepcopy(document["images"][image_id])
        if isinstance(image.get("bufferView"), int):
            image["bufferView"] = view_map[image["bufferView"]]
        new_images.append(image)
    new_samplers = [copy.deepcopy(document["samplers"][sampler_id]) for sampler_id in sorted(used_samplers)]

    for mesh in new_meshes:
        for primitive in mesh["primitives"]:
            primitive["attributes"] = {key: accessor_map[value] for key, value in primitive.get("attributes", {}).items()}
            if isinstance(primitive.get("indices"), int):
                primitive["indices"] = accessor_map[primitive["indices"]]
            if isinstance(primitive.get("material"), int):
                primitive["material"] = material_map[primitive["material"]]
            if "targets" in primitive:
                primitive["targets"] = [{key: accessor_map[value] for key, value in target.items()} for target in primitive["targets"]]

    node_map = {old: new for new, old in enumerate(sorted(selected_nodes))}
    new_nodes = []
    for old_node_id in sorted(selected_nodes):
        node = copy.deepcopy(document["nodes"][old_node_id])
        if isinstance(node.get("mesh"), int):
            node["mesh"] = mesh_map[node["mesh"]]
        if "children" in node:
            node["children"] = [node_map[child] for child in node["children"] if child in selected_nodes]
        new_nodes.append(node)

    roots = []
    for scene in document.get("scenes", []):
        roots.extend(node_map[node] for node in scene.get("nodes", []) if node in selected_nodes)
    if not roots:
        roots = [node_map[min(selected_nodes)]]

    result = {
        "asset": copy.deepcopy(document.get("asset", {"version": "2.0"})),
        "scene": 0,
        "scenes": [{"nodes": roots}],
        "nodes": new_nodes,
        "meshes": new_meshes,
        "materials": new_materials,
        "accessors": new_accessors,
        "bufferViews": new_views,
        "buffers": [{"byteLength": len(packed)}],
    }
    if new_textures:
        result["textures"] = new_textures
    if new_images:
        result["images"] = new_images
    if new_samplers:
        result["samplers"] = new_samplers

    json_chunk = json.dumps(result, separators=(",", ":")).encode("utf-8")
    while len(json_chunk) % 4:
        json_chunk += b" "
    while len(packed) % 4:
        packed.append(0)
    total = 12 + 8 + len(json_chunk) + 8 + len(packed)
    glb = struct.pack("<III", GLB_MAGIC, 2, total) + struct.pack("<II", len(json_chunk), JSON_CHUNK) + json_chunk + struct.pack("<II", len(packed), BIN_CHUNK) + packed
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(glb)
    return hashlib.sha256(glb).hexdigest(), len(glb)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path, help="verified private road_car.glb")
    parser.add_argument("output_dir", type=Path)
    args = parser.parse_args()
    document, binary = load_glb(args.source)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    lod1 = args.output_dir / "toyota_chaser_v_lod1.glb"
    lod2 = args.output_dir / "toyota_chaser_v_lod2.glb"
    sha1, bytes1 = build_subset(document, binary, LOD1_NODES, {}, lod1)
    sha2, bytes2 = build_subset(document, binary, LOD2_NODES, {4: {1}}, lod2)
    print(json.dumps({
        "source_sha256": SOURCE_SHA256,
        "lod1": {"path": str(lod1), "bytes": bytes1, "sha256": sha1},
        "lod2": {"path": str(lod2), "bytes": bytes2, "sha256": sha2},
    }, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
