#!/usr/bin/env python3
"""Profile compiled YMB1 packs without inventing synthetic production data."""
from __future__ import annotations

import argparse
import json
import statistics
import struct
import time
from pathlib import Path

HEADER = struct.Struct("<4sI")
INDEX = struct.Struct("<HHII")
MAGIC = b"YMB1"
MAX_CELLS_PER_TILE = 256


def scan(root: Path) -> dict:
    manifest = json.loads((root / "manifest.json").read_text())
    cells = 0
    pack_bytes = 0
    largest = None
    for tile in manifest.get("tiles", []):
        path = root / str(tile["file"])
        size = path.stat().st_size
        pack_bytes += size
        with path.open("rb") as file:
            magic, count = HEADER.unpack(file.read(HEADER.size))
            if magic != MAGIC or count > MAX_CELLS_PER_TILE:
                raise ValueError(f"Invalid YMB1 header: {path}")
            data_start = HEADER.size + count * INDEX.size
            for _ in range(count):
                local_x, local_z, offset, length = INDEX.unpack(file.read(INDEX.size))
                if offset < data_start or length <= 0 or offset + length > size:
                    raise ValueError(f"Invalid YMB1 index bounds: {path}")
                cells += 1
                candidate = {
                    "tile": [int(tile["x"]), int(tile["z"])],
                    "local_cell": [local_x, local_z],
                    "file": str(tile["file"]),
                    "offset": offset,
                    "compressed_bytes": length,
                }
                if largest is None or length > largest["compressed_bytes"]:
                    largest = candidate
    if largest is None:
        raise ValueError("No populated YMB1 cells")
    if cells != int(manifest.get("stats", {}).get("cells", cells)):
        raise ValueError("YMB1 index cell count differs from manifest")
    return {
        "packs": len(manifest.get("tiles", [])),
        "cells": cells,
        "pack_bytes": pack_bytes,
        "largest_compressed_cell": largest,
        "source_sha256": manifest.get("source_sha256", ""),
        "crs": manifest.get("crs", ""),
        "origin": manifest.get("origin", {}),
    }


def decode_stress_cell(root: Path, profile: dict, iterations: int = 12) -> dict:
    from build_buildings import read_cell

    cell = profile["largest_compressed_cell"]
    path = root / cell["file"]
    local_x, local_z = map(int, cell["local_cell"])
    warmup = read_cell(path, local_x, local_z)
    if not warmup:
        raise ValueError("Largest compressed YMB1 cell decoded empty")
    if not all(str(record[0]).startswith(("w", "r")) for record in warmup[: min(64, len(warmup))]):
        raise ValueError("Stress cell contains non-OSM source identifiers")
    samples = []
    for _ in range(max(1, iterations)):
        started = time.perf_counter_ns()
        records = read_cell(path, local_x, local_z)
        samples.append((time.perf_counter_ns() - started) / 1000.0)
        if len(records) != len(warmup):
            raise ValueError("Stress-cell decode record count changed between iterations")
    return {
        **cell,
        "records": len(warmup),
        "median_decode_us": round(statistics.median(samples), 2),
        "mean_decode_us": round(statistics.mean(samples), 2),
        "max_decode_us": round(max(samples), 2),
        "iterations": len(samples),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path, help="Compiled building dataset root")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--iterations", type=int, default=12)
    args = parser.parse_args()
    profile = scan(args.root)
    profile["stress_decode"] = decode_stress_cell(args.root, profile, args.iterations)
    encoded = json.dumps(profile, indent=2, sort_keys=True)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded)
    print("YARDMAN_BUILDING_PACK_PROFILE PASS")
    print(json.dumps(profile, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
