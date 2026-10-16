#!/usr/bin/env python3
"""Inspect recovered RR3 JSR-184/M3G files without third-party dependencies.

The tool validates the M3G signature, section lengths, Adler-32 checksums and
object framing. It reports object-type counts and embedded LOD labels so Yardman
can compare RR3 source richness before selecting components for conversion.

This is a structural inspector, not a geometry converter.
"""
from __future__ import annotations

import argparse
import collections
import json
import re
import struct
import zlib
from pathlib import Path

SIGNATURE = bytes.fromhex("ab4a5352313834bb0d0a1a0a")
OBJECT_TYPES = {
    0: "Header",
    1: "AnimationController",
    2: "AnimationTrack",
    3: "Appearance",
    4: "Background",
    5: "Camera",
    6: "CompositingMode",
    7: "Fog",
    8: "PolygonMode",
    9: "Group",
    10: "Image2D",
    11: "TriangleStripArray",
    12: "Light",
    13: "Material",
    14: "Mesh",
    15: "MorphingMesh",
    16: "SkinnedMesh",
    17: "Texture2D",
    18: "Sprite3D",
    19: "KeyframeSequence",
    20: "VertexArray",
    21: "VertexBuffer",
    22: "World",
    255: "ExternalReference",
}
LOD_RE = re.compile(rb"LOD_[A-Za-z0-9_ .-]{3,120}")


def section_payload(data: bytes, pos: int) -> tuple[dict, bytes, int]:
    if pos + 13 > len(data):
        raise ValueError(("short M3G section header", pos, len(data)))
    compression = data[pos]
    total_length = struct.unpack_from("<I", data, pos + 1)[0]
    uncompressed_length = struct.unpack_from("<I", data, pos + 5)[0]
    if total_length < 13 or pos + total_length > len(data):
        raise ValueError(("invalid M3G section length", pos, total_length, len(data)))

    checksum_pos = pos + total_length - 4
    stored_checksum = struct.unpack_from("<I", data, checksum_pos)[0]
    calculated_checksum = zlib.adler32(data[pos:checksum_pos]) & 0xFFFFFFFF
    if stored_checksum != calculated_checksum:
        raise ValueError((
            "M3G section Adler-32 mismatch",
            pos,
            f"{stored_checksum:08x}",
            f"{calculated_checksum:08x}",
        ))

    encoded = data[pos + 9 : checksum_pos]
    if compression == 0:
        payload = encoded
    elif compression == 1:
        payload = zlib.decompress(encoded)
    else:
        raise NotImplementedError(("unsupported M3G section compression", compression))
    if len(payload) != uncompressed_length:
        raise ValueError((
            "M3G uncompressed section length mismatch",
            pos,
            len(payload),
            uncompressed_length,
        ))

    return {
        "offset": pos,
        "compression": compression,
        "total_bytes": total_length,
        "encoded_payload_bytes": len(encoded),
        "uncompressed_payload_bytes": uncompressed_length,
        "adler32": f"{stored_checksum:08x}",
    }, payload, pos + total_length


def parse_objects(payload: bytes, section_index: int) -> list[dict]:
    objects = []
    pos = 0
    while pos < len(payload):
        if pos + 5 > len(payload):
            raise ValueError(("short M3G object header", section_index, pos, len(payload)))
        object_type = payload[pos]
        object_length = struct.unpack_from("<I", payload, pos + 1)[0]
        end = pos + 5 + object_length
        if end > len(payload):
            raise ValueError((
                "M3G object overruns section",
                section_index,
                object_type,
                object_length,
                pos,
                len(payload),
            ))
        body = payload[pos + 5 : end]
        objects.append({
            "section": section_index,
            "section_payload_offset": pos,
            "type_id": object_type,
            "type": OBJECT_TYPES.get(object_type, f"Unknown_{object_type}"),
            "payload_bytes": object_length,
            "lod_labels": sorted({
                match.decode("latin1", errors="replace")
                for match in LOD_RE.findall(body)
            }),
        })
        pos = end
    return objects


def inspect(path: Path, include_objects: bool = False) -> dict:
    data = path.read_bytes()
    if data[: len(SIGNATURE)] != SIGNATURE:
        raise ValueError(("not a JSR-184 M3G file", str(path), data[:12].hex()))

    pos = len(SIGNATURE)
    sections = []
    objects = []
    section_index = 0
    while pos < len(data):
        section, payload, pos = section_payload(data, pos)
        section["index"] = section_index
        parsed = parse_objects(payload, section_index)
        section["object_count"] = len(parsed)
        sections.append(section)
        objects.extend(parsed)
        section_index += 1
    if pos != len(data):
        raise ValueError(("M3G trailing bytes", pos, len(data)))

    type_counts = collections.Counter(obj["type"] for obj in objects)
    lod_labels = sorted({label for obj in objects for label in obj["lod_labels"]})
    lod_prefix_counts = collections.Counter()
    for label in lod_labels:
        match = re.match(r"(LOD_[A-Z]+)", label)
        if match:
            lod_prefix_counts[match.group(1)] += 1

    result = {
        "path": str(path),
        "file_bytes": len(data),
        "signature": "JSR184",
        "section_count": len(sections),
        "section_checksums": "PASS",
        "object_count": len(objects),
        "object_type_counts": dict(sorted(type_counts.items())),
        "mesh_objects": type_counts.get("Mesh", 0),
        "vertex_array_objects": type_counts.get("VertexArray", 0),
        "vertex_buffer_objects": type_counts.get("VertexBuffer", 0),
        "triangle_strip_objects": type_counts.get("TriangleStripArray", 0),
        "lod_label_count": len(lod_labels),
        "lod_prefix_counts": dict(sorted(lod_prefix_counts.items())),
        "lod_labels": lod_labels,
        "sections": sections,
    }
    if include_objects:
        result["objects"] = objects
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", type=Path, nargs="+")
    parser.add_argument("--include-objects", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    reports = [inspect(path, args.include_objects) for path in args.paths]
    result = {
        "format_version": 1,
        "files": reports,
        "summary": {
            "files": len(reports),
            "bytes": sum(item["file_bytes"] for item in reports),
            "objects": sum(item["object_count"] for item in reports),
            "meshes": sum(item["mesh_objects"] for item in reports),
            "all_section_checksums": "PASS",
        },
    }
    text = json.dumps(result, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
    print(text, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
