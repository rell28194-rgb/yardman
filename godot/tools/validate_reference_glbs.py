#!/usr/bin/env python3
"""Validate optional private GLB model geometry without third-party packages.

This checks file structure, mesh POSITION accessor declarations, finite bounds,
and gross scale. It intentionally does not claim material/render/collision quality.
"""
from __future__ import annotations

import argparse
import json
import math
import struct
from pathlib import Path
from typing import Any

GLB_MAGIC = b"glTF"
JSON_CHUNK = 0x4E4F534A
TRIANGLES = 4


class ValidationError(ValueError):
    pass


def _finite_vec(values: Any, label: str) -> list[float]:
    if not isinstance(values, list) or len(values) != 3:
        raise ValidationError(f"{label} must be a three-component vector")
    out = [float(v) for v in values]
    if not all(math.isfinite(v) for v in out):
        raise ValidationError(f"{label} contains non-finite values")
    return out


def read_glb_json(path: Path) -> dict[str, Any]:
    data = path.read_bytes()
    if len(data) < 20:
        raise ValidationError("GLB is too small")
    magic, version, declared_length = struct.unpack_from("<4sII", data, 0)
    if magic != GLB_MAGIC:
        raise ValidationError("invalid GLB magic")
    if version != 2:
        raise ValidationError(f"unsupported GLB version {version}")
    if declared_length != len(data):
        raise ValidationError(f"GLB length mismatch declared={declared_length} actual={len(data)}")
    offset = 12
    document = None
    while offset < len(data):
        if offset + 8 > len(data):
            raise ValidationError("truncated GLB chunk header")
        chunk_length, chunk_type = struct.unpack_from("<II", data, offset)
        offset += 8
        end = offset + chunk_length
        if end > len(data):
            raise ValidationError("truncated GLB chunk payload")
        if chunk_type == JSON_CHUNK and document is None:
            try:
                document = json.loads(data[offset:end].rstrip(b" \t\r\n\0").decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise ValidationError(f"invalid GLB JSON: {exc}") from exc
        offset = end
    if document is None:
        raise ValidationError("GLB JSON chunk missing")
    if str(document.get("asset", {}).get("version", "")) != "2.0":
        raise ValidationError("glTF asset.version must be 2.0")
    return document


def validate_glb(path: Path, *, max_extent_m: float = 100.0, min_extent_m: float = 0.001) -> dict[str, Any]:
    doc = read_glb_json(path)
    accessors = doc.get("accessors", [])
    meshes = doc.get("meshes", [])
    if not isinstance(accessors, list) or not isinstance(meshes, list) or not meshes:
        raise ValidationError("GLB must contain mesh/accessor arrays")

    primitive_count = 0
    vertex_count = 0
    triangle_count = 0
    overall_min = [math.inf, math.inf, math.inf]
    overall_max = [-math.inf, -math.inf, -math.inf]

    for mesh_index, mesh in enumerate(meshes):
        primitives = mesh.get("primitives", []) if isinstance(mesh, dict) else []
        if not isinstance(primitives, list):
            raise ValidationError(f"mesh {mesh_index} primitives are invalid")
        for primitive_index, primitive in enumerate(primitives):
            if not isinstance(primitive, dict):
                raise ValidationError(f"mesh {mesh_index} primitive {primitive_index} is invalid")
            attrs = primitive.get("attributes", {})
            if not isinstance(attrs, dict) or "POSITION" not in attrs:
                raise ValidationError(f"mesh {mesh_index} primitive {primitive_index} has no POSITION")
            accessor_index = int(attrs["POSITION"])
            if accessor_index < 0 or accessor_index >= len(accessors):
                raise ValidationError("POSITION accessor index out of bounds")
            accessor = accessors[accessor_index]
            if not isinstance(accessor, dict):
                raise ValidationError("POSITION accessor is invalid")
            if accessor.get("type") != "VEC3" or int(accessor.get("componentType", -1)) != 5126:
                raise ValidationError("POSITION accessor must be FLOAT VEC3")
            count = int(accessor.get("count", 0))
            if count <= 0:
                raise ValidationError("POSITION accessor has no vertices")
            low = _finite_vec(accessor.get("min"), "POSITION min")
            high = _finite_vec(accessor.get("max"), "POSITION max")
            if any(hi < lo for lo, hi in zip(low, high)):
                raise ValidationError("POSITION max is below min")
            for axis in range(3):
                overall_min[axis] = min(overall_min[axis], low[axis])
                overall_max[axis] = max(overall_max[axis], high[axis])
            vertex_count += count
            primitive_count += 1

            mode = int(primitive.get("mode", TRIANGLES))
            if mode == TRIANGLES:
                if "indices" in primitive:
                    index_id = int(primitive["indices"])
                    if index_id < 0 or index_id >= len(accessors):
                        raise ValidationError("index accessor out of bounds")
                    index_count = int(accessors[index_id].get("count", 0))
                    if index_count <= 0 or index_count % 3:
                        raise ValidationError("triangle index count must be positive and divisible by 3")
                    triangle_count += index_count // 3
                elif count % 3 == 0:
                    triangle_count += count // 3

    if primitive_count == 0 or vertex_count == 0:
        raise ValidationError("GLB has no usable mesh primitives")
    extents = [hi - lo for lo, hi in zip(overall_min, overall_max)]
    max_extent = max(extents)
    nonzero = [value for value in extents if value > 1e-9]
    min_nonzero = min(nonzero) if nonzero else 0.0
    if max_extent > max_extent_m:
        raise ValidationError(f"model extent {max_extent:.6g}m exceeds {max_extent_m:.6g}m")
    if max_extent < min_extent_m:
        raise ValidationError(f"model extent {max_extent:.6g}m is below {min_extent_m:.6g}m")
    return {
        "file": path.name,
        "meshes": len(meshes),
        "primitives": primitive_count,
        "vertices": vertex_count,
        "triangles_declared": triangle_count,
        "bounds_min": overall_min,
        "bounds_max": overall_max,
        "extents_m": extents,
        "max_extent_m": max_extent,
        "min_nonzero_extent_m": min_nonzero,
    }


def validate_directory(root: Path, *, max_extent_m: float = 100.0, min_extent_m: float = 0.001) -> dict[str, Any]:
    files = sorted(root.glob("*.glb"))
    if not files:
        raise ValidationError(f"no GLB files found in {root}")
    records = [validate_glb(path, max_extent_m=max_extent_m, min_extent_m=min_extent_m) for path in files]
    return {"result": "PASS", "root": str(root), "models": len(records), "records": records}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", type=Path,
                        default=Path(__file__).resolve().parents[1] / "assets" / "user_reference")
    parser.add_argument("--max-extent-m", type=float, default=100.0)
    parser.add_argument("--min-extent-m", type=float, default=0.001)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    result = validate_directory(args.root, max_extent_m=args.max_extent_m, min_extent_m=args.min_extent_m)
    if args.json:
        print(json.dumps(result, sort_keys=True))
    else:
        print(f"YARDMAN_REFERENCE_GLB_PASS models={result['models']}")


if __name__ == "__main__":
    main()
