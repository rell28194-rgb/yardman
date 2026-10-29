#!/usr/bin/env python3
"""Build a source-hierarchy descriptor and audit a converted GLB.

Input is the source_hierarchy.json format already preserved by Yardman's Beta1
CarX recovery.  No Unity runtime or third-party Python packages are required.

The descriptor deliberately keeps raw Unity transforms *and* a Godot-space
mapping.  Existing CarX production provenance established the coordinate rule:
retain X/Y and reflect Z.  For rotations this is the basis conjugation
S*R*S, represented for a quaternion as (-x, -y, z, w).

This tool does not decide that a GLB is complete merely because geometry is
present.  It reports every original GameObject missing from the converted scene.
"""

from __future__ import annotations

import argparse
import json
import struct
from pathlib import Path
from typing import Any


def _pid(ref: Any) -> int:
    if not isinstance(ref, dict):
        return 0
    try:
        return int(ref.get("m_PathID", 0) or 0)
    except (TypeError, ValueError):
        return 0


def _v3(value: dict[str, Any] | None, default: tuple[float, float, float]) -> list[float]:
    value = value or {}
    return [
        float(value.get("x", default[0])),
        float(value.get("y", default[1])),
        float(value.get("z", default[2])),
    ]


def _q(value: dict[str, Any] | None) -> list[float]:
    value = value or {}
    return [
        float(value.get("x", 0.0)),
        float(value.get("y", 0.0)),
        float(value.get("z", 0.0)),
        float(value.get("w", 1.0)),
    ]


def _godot_position(p: list[float]) -> list[float]:
    return [p[0], p[1], -p[2]]


def _godot_quaternion(q: list[float]) -> list[float]:
    # Basis reflection across Z: S*R*S.
    return [-q[0], -q[1], q[2], q[3]]


def read_glb_node_names(path: Path) -> list[str]:
    raw = path.read_bytes()
    if len(raw) < 20 or raw[:4] != b"glTF":
        raise ValueError(f"not a GLB: {path}")
    version, total_length = struct.unpack_from("<II", raw, 4)
    if version != 2 or total_length > len(raw):
        raise ValueError(f"unsupported/corrupt GLB header: version={version}, length={total_length}")
    off = 12
    json_doc = None
    while off + 8 <= total_length:
        chunk_len, chunk_type = struct.unpack_from("<II", raw, off)
        off += 8
        chunk = raw[off:off + chunk_len]
        off += chunk_len
        if chunk_type == 0x4E4F534A:  # JSON
            json_doc = json.loads(chunk.decode("utf-8").rstrip(" \t\r\n\x00"))
            break
    if json_doc is None:
        raise ValueError("GLB contains no JSON chunk")
    return [str(node.get("name")) for node in json_doc.get("nodes", []) if node.get("name")]


def classify_name(name: str) -> list[str]:
    n = name.lower()
    roles: list[str] = []
    tests = (
        ("wheel", "wheel"),
        ("caliper", "brake"),
        ("tyre", "tyre"),
        ("rim", "rim"),
        ("camera", "camera"),
        ("driver", "driver"),
        ("exhaust", "exhaust"),
        ("engine", "engine"),
        ("collider", "collision"),
        ("colliders", "collision"),
        ("obstacle", "collision"),
        ("glass", "glass"),
        ("stoplight", "light"),
        ("light", "light"),
        ("interior", "interior"),
        ("steering", "steering"),
        ("bodyh", "body_lod0"),
        ("bodyl", "body_lod1"),
        ("particle", "vfx"),
        ("shadow", "shadow"),
    )
    for needle, role in tests:
        if needle in n and role not in roles:
            roles.append(role)
    if n.startswith("col") and "collision" not in roles:
        roles.append("collision")
    return roles


def build_descriptor(source: dict[str, Any], glb_names: set[str] | None) -> dict[str, Any]:
    objects = source.get("objects") or {}

    gameobjects: dict[int, dict[str, Any]] = {}
    transforms: dict[int, dict[str, Any]] = {}

    for pid_text, obj in objects.items():
        try:
            pid = int(pid_text)
        except ValueError:
            continue
        typ = obj.get("type")
        tree = obj.get("tree") or {}
        if typ == "GameObject":
            gameobjects[pid] = tree
        elif typ == "Transform":
            transforms[pid] = tree

    go_to_transform: dict[int, int] = {}
    transform_to_go: dict[int, int] = {}
    for tpid, tree in transforms.items():
        gpid = _pid(tree.get("m_GameObject"))
        if gpid:
            go_to_transform[gpid] = tpid
            transform_to_go[tpid] = gpid

    # Component lists are useful evidence even when a converter does not understand
    # every MonoBehaviour/renderer type yet.
    nodes: list[dict[str, Any]] = []
    missing_glb: list[str] = []
    exact_glb_matches = 0

    for gpid, tree in sorted(gameobjects.items()):
        name = str(tree.get("m_Name") or f"GameObject_{gpid}")
        tpid = go_to_transform.get(gpid, 0)
        transform = transforms.get(tpid, {})
        father_tpid = _pid(transform.get("m_Father"))
        father_gpid = transform_to_go.get(father_tpid, 0)
        father_name = None
        if father_gpid in gameobjects:
            father_name = str(gameobjects[father_gpid].get("m_Name") or f"GameObject_{father_gpid}")

        position = _v3(transform.get("m_LocalPosition"), (0.0, 0.0, 0.0))
        rotation = _q(transform.get("m_LocalRotation"))
        scale = _v3(transform.get("m_LocalScale"), (1.0, 1.0, 1.0))
        component_ids = [_pid(c.get("component")) for c in tree.get("m_Component", []) if isinstance(c, dict)]
        component_ids = [x for x in component_ids if x]

        present = glb_names is None or name in glb_names
        if glb_names is not None:
            if present:
                exact_glb_matches += 1
            else:
                missing_glb.append(name)

        nodes.append({
            "game_object_path_id": gpid,
            "transform_path_id": tpid or None,
            "name": name,
            "parent_game_object_path_id": father_gpid or None,
            "parent_name": father_name,
            "active": bool(tree.get("m_IsActive", True)),
            "layer": tree.get("m_Layer"),
            "tag": tree.get("m_Tag"),
            "roles": classify_name(name),
            "component_path_ids": component_ids,
            "unity_local": {
                "position": position,
                "rotation_xyzw": rotation,
                "scale": scale,
            },
            "godot_local": {
                "position": _godot_position(position),
                "rotation_xyzw": _godot_quaternion(rotation),
                "scale": scale,
            },
            "exact_name_present_in_glb": present if glb_names is not None else None,
        })

    role_counts: dict[str, int] = {}
    for node in nodes:
        for role in node["roles"]:
            role_counts[role] = role_counts.get(role, 0) + 1

    report = {
        "format_version": 1,
        "source_unit": source.get("source_unit"),
        "identity": source.get("identity"),
        "source_object_count": len(objects),
        "source_gameobject_count": len(gameobjects),
        "source_transform_count": len(transforms),
        "role_counts": dict(sorted(role_counts.items())),
        "nodes": nodes,
    }

    if glb_names is not None:
        report["glb_audit"] = {
            "glb_named_node_count": len(glb_names),
            "source_gameobject_exact_name_matches": exact_glb_matches,
            "source_gameobject_missing_count": len(missing_glb),
            "source_gameobjects_missing_from_glb": missing_glb,
            "flattening_detected": bool(missing_glb),
        }
    return report


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("source_hierarchy", type=Path)
    ap.add_argument("--glb", type=Path)
    ap.add_argument("--output", type=Path, required=True)
    args = ap.parse_args()

    source = json.loads(args.source_hierarchy.read_text(encoding="utf-8"))
    glb_names = set(read_glb_node_names(args.glb)) if args.glb else None
    report = build_descriptor(source, glb_names)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    audit = report.get("glb_audit")
    if audit:
        print(
            f"{report.get('identity')}: source GameObjects={report['source_gameobject_count']}, "
            f"exact GLB matches={audit['source_gameobject_exact_name_matches']}, "
            f"missing={audit['source_gameobject_missing_count']}"
        )
        # Exit 2 is intentional: CI can distinguish a valid descriptor that detected
        # flattening from a parser/runtime failure.
        return 2 if audit["flattening_detected"] else 0
    print(f"{report.get('identity')}: source GameObjects={report['source_gameobject_count']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
