"""Deterministic binary road-routing pack shared with Yardman's Rust core."""
from __future__ import annotations

import hashlib
import math
import struct
from pathlib import Path

ROUTE_PACK_MAGIC = b"YMRG"
ROUTE_PACK_VERSION = 1
HEADER = struct.Struct("<4sHHHHIIIQ")
NODE = struct.Struct("<IHHfff")
EDGE = struct.Struct("<IHBbIIffI")


def build_route_pack(network: dict) -> bytes:
    nodes = sorted((str(identifier), record) for identifier, record in network.get("nodes", {}).items())
    edges = sorted((str(identifier), record) for identifier, record in network.get("edges", {}).items())
    if not nodes:
        raise ValueError("route pack requires at least one node")
    if len(edges) > 0x7FFFFFFF:
        raise ValueError("route pack edge count exceeds routing ID range")

    strings = bytearray()
    node_records = bytearray()
    edge_records = bytearray()
    node_indices = {}

    def append_id(identifier: str) -> tuple[int, int]:
        encoded = identifier.encode("utf-8")
        if not encoded:
            raise ValueError("route stable ID cannot be empty")
        if len(encoded) > 0xFFFF:
            raise ValueError("route stable ID exceeds 65535 UTF-8 bytes")
        offset = len(strings)
        if offset > 0xFFFFFFFF or offset + len(encoded) > 0xFFFFFFFF:
            raise ValueError("route string table exceeds 4 GiB")
        strings.extend(encoded)
        return offset, len(encoded)

    for index, (identifier, record) in enumerate(nodes):
        if str(record.get("id", identifier)) != identifier:
            raise ValueError(f"route node identity mismatch for {identifier}")
        position = record.get("position")
        if not isinstance(position, (list, tuple)) or len(position) != 3:
            raise ValueError(f"route node {identifier} must have a 3D position")
        x, y, z = (float(value) for value in position)
        if not all(math.isfinite(value) for value in (x, y, z)):
            raise ValueError(f"route node {identifier} position must be finite")
        offset, length = append_id(identifier)
        node_records.extend(NODE.pack(offset, length, 0, x, y, z))
        node_indices[identifier] = index

    for identifier, record in edges:
        if str(record.get("id", identifier)) != identifier:
            raise ValueError(f"route edge identity mismatch for {identifier}")
        source = str(record.get("from", ""))
        target = str(record.get("to", ""))
        if source not in node_indices or target not in node_indices or source == target:
            raise ValueError(f"route edge {identifier} references an invalid node")
        length_m = float(record.get("length_m", 0.0))
        if not math.isfinite(length_m) or length_m <= 0.0:
            raise ValueError(f"route edge {identifier} length must be finite and positive")
        class_id = int(record.get("class_id", 0))
        if not 0 <= class_id <= 0xFF:
            raise ValueError(f"route edge {identifier} class_id must fit u8")
        direction = int(record.get("direction", 0))
        if direction not in (-1, 0, 1):
            raise ValueError(f"route edge {identifier} direction must be -1, 0, or 1")
        raw_speed = record.get("speed_limit_mps")
        speed = 0.0 if raw_speed is None else float(raw_speed)
        if not math.isfinite(speed) or speed < 0.0:
            raise ValueError(f"route edge {identifier} speed must be finite and non-negative")
        flags = int(record.get("flags", 0))
        if not 0 <= flags <= 0xFFFFFFFF:
            raise ValueError(f"route edge {identifier} flags must fit u32")
        offset, stable_id_len = append_id(identifier)
        edge_records.extend(EDGE.pack(
            offset,
            stable_id_len,
            class_id,
            direction,
            node_indices[source],
            node_indices[target],
            length_m,
            speed,
            flags,
        ))

    if len(nodes) > 0xFFFFFFFF or len(edges) > 0xFFFFFFFF or len(strings) > 0xFFFFFFFF:
        raise ValueError("route pack table exceeds v1 count limits")
    header = HEADER.pack(
        ROUTE_PACK_MAGIC,
        ROUTE_PACK_VERSION,
        HEADER.size,
        NODE.size,
        EDGE.size,
        len(nodes),
        len(edges),
        len(strings),
        0,
    )
    return bytes(header + node_records + edge_records + strings)


def write_route_pack(network: dict, path: Path) -> dict:
    payload = build_route_pack(network)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)
    return {
        "format": ROUTE_PACK_VERSION,
        "file": path.name,
        "bytes": len(payload),
        "sha256": hashlib.sha256(payload).hexdigest(),
        "nodes": len(network.get("nodes", {})),
        "edges": len(network.get("edges", {})),
        "header_bytes": HEADER.size,
        "node_record_bytes": NODE.size,
        "edge_record_bytes": EDGE.size,
        "endianness": "little",
        "stable_id_order": "lexicographic UTF-8",
    }
