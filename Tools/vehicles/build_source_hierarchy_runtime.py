#!/usr/bin/env python3
"""Build a private/runtime-safe Godot hierarchy descriptor from recovered Unity objects.

The converter deliberately does not copy meshes, textures, audio, or other donor media.
It preserves transform semantics so a later private vehicle pack can attach recovered
render/collision/audio resources to the original source pivots instead of flattening
everything into a hero GLB.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def _vec3(value: dict[str, Any], reflect_z: bool = False) -> list[float]:
    x = float(value.get("x", 0.0))
    y = float(value.get("y", 0.0))
    z = float(value.get("z", 0.0))
    return [x, y, -z if reflect_z else z]


def _quat_reflect_z(value: dict[str, Any]) -> list[float]:
    """Return quaternion for S*R*S where S=diag(1,1,-1).

    For Unity quaternion (x,y,z,w), the equivalent reflected right-handed
    rotation is (-x,-y,z,w). This matches the project's existing geometry
    conversion contract and keeps local transform composition intact.
    """

    return [
        -float(value.get("x", 0.0)),
        -float(value.get("y", 0.0)),
        float(value.get("z", 0.0)),
        float(value.get("w", 1.0)),
    ]


def build_descriptor(source: dict[str, Any]) -> dict[str, Any]:
    objects = source.get("objects", {})
    if not isinstance(objects, dict):
        raise ValueError("source hierarchy has no objects dictionary")

    game_objects: dict[int, dict[str, Any]] = {}
    transforms: dict[int, dict[str, Any]] = {}
    for raw_path_id, raw_object in objects.items():
        if not isinstance(raw_object, dict):
            continue
        path_id = int(raw_path_id)
        tree = raw_object.get("tree", {})
        if not isinstance(tree, dict):
            continue
        object_type = str(raw_object.get("type", ""))
        if object_type == "GameObject":
            game_objects[path_id] = tree
        elif object_type == "Transform":
            transforms[path_id] = tree

    transform_to_game_object: dict[int, int] = {}
    for transform_id, tree in transforms.items():
        game_object_ref = tree.get("m_GameObject", {})
        if not isinstance(game_object_ref, dict):
            raise ValueError(f"transform {transform_id} has no GameObject reference")
        transform_to_game_object[transform_id] = int(game_object_ref.get("m_PathID", 0))

    roots = [
        transform_id
        for transform_id, tree in transforms.items()
        if int((tree.get("m_Father") or {}).get("m_PathID", 0)) == 0
    ]
    if len(roots) != 1:
        raise ValueError(f"expected one root transform, got {roots}")

    root_transform_id = roots[0]
    root_game_object_id = transform_to_game_object[root_transform_id]
    nodes: list[dict[str, Any]] = []

    for transform_id in sorted(transforms):
        tree = transforms[transform_id]
        game_object_id = transform_to_game_object[transform_id]
        game_object = game_objects.get(game_object_id)
        if game_object is None:
            raise ValueError(
                f"transform {transform_id} references missing GameObject {game_object_id}"
            )
        parent_ref = tree.get("m_Father") or {}
        parent_transform_id = int(parent_ref.get("m_PathID", 0))
        is_root = transform_id == root_transform_id
        nodes.append(
            {
                "transform_path_id": transform_id,
                "game_object_path_id": game_object_id,
                "name": str(game_object.get("m_Name", "")),
                "active": bool(game_object.get("m_IsActive", True)),
                "layer": int(game_object.get("m_Layer", 0)),
                "parent_transform_path_id": parent_transform_id,
                # A recovered prefab may have been serialized at an arbitrary
                # Unity scene position. Yardman owns world placement, so only
                # the root's old world placement is normalized away.
                "local_position_m": (
                    [0.0, 0.0, 0.0]
                    if is_root
                    else _vec3(tree.get("m_LocalPosition", {}), reflect_z=True)
                ),
                "local_rotation_xyzw": (
                    [0.0, 0.0, 0.0, 1.0]
                    if is_root
                    else _quat_reflect_z(tree.get("m_LocalRotation", {}))
                ),
                "local_scale": _vec3(tree.get("m_LocalScale", {})),
            }
        )

    return {
        "format_version": 1,
        "coordinate_system": "godot_right_handed_y_up_minus_z_forward",
        "conversion": "unity_to_godot_reflect_z_transform_conjugation",
        "source_unit": str(source.get("source_unit", "")),
        "identity": str(source.get("identity", "")),
        "root_transform_path_id": root_transform_id,
        "root_game_object_path_id": root_game_object_id,
        "source_node_count": len(nodes),
        "root_world_transform_normalized": True,
        "nodes": nodes,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--expected-nodes", type=int, default=None)
    args = parser.parse_args()

    with args.source.open("r", encoding="utf-8") as handle:
        source = json.load(handle)
    descriptor = build_descriptor(source)

    if args.expected_nodes is not None and descriptor["source_node_count"] != args.expected_nodes:
        raise SystemExit(
            f"expected {args.expected_nodes} source nodes, got {descriptor['source_node_count']}"
        )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as handle:
        json.dump(descriptor, handle, indent=2, sort_keys=True)
        handle.write("\n")

    print(
        "YARDMAN_SOURCE_HIERARCHY_RUNTIME_PASS "
        f"identity={descriptor['identity']} "
        f"nodes={descriptor['source_node_count']} root_normalized=1"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
