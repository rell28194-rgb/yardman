#!/usr/bin/env python3
"""Build a content-addressed transitive Unity serialized-file closure for one CarX root.

The source summary is the deterministic inventory emitted by the CarX recovery lane.
Every extracted member is checked for both byte length and SHA-256 before use.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import zipfile
from pathlib import Path

from assemble_carx_vehicle_glb import read_sf


def _index(summary: dict) -> dict[str, dict]:
    return {str(row["basename"]): row for row in summary["source_data_files"]}


def _extract_verified(name: str, by_name: dict[str, dict], archive: zipfile.ZipFile, cache: Path) -> Path:
    row = by_name[name]
    out = cache / name
    if out.exists():
        payload = out.read_bytes()
    else:
        payload = b"".join(archive.read(part) for part in row["parts"])
    actual_sha = hashlib.sha256(payload).hexdigest()
    if len(payload) != int(row["bytes"]) or actual_sha != str(row["sha256"]):
        raise RuntimeError(f"identity mismatch for {name}: bytes/sha256 differ from source inventory")
    if not out.exists():
        out.write_bytes(payload)
    return out


def build_closure(summary_path: Path, archive_path: Path, cache: Path, root: str, identity: str) -> dict:
    summary = json.loads(summary_path.read_text())
    by_name = _index(summary)
    if root not in by_name:
        raise KeyError(f"root {root} is not present in source inventory")
    cache.mkdir(parents=True, exist_ok=True)
    todo = [root]
    seen: set[str] = set()
    records: list[dict] = []
    unresolved: set[str] = set()
    with zipfile.ZipFile(archive_path) as archive:
        while todo:
            name = todo.pop(0)
            if name in seen:
                continue
            seen.add(name)
            if name not in by_name:
                unresolved.add(name)
                continue
            source = _extract_verified(name, by_name, archive, cache)
            serialized = read_sf(source)
            direct_refs: list[str] = []
            for external in serialized["externals"]:
                ref_name = Path(str(external["path"])).name
                if ref_name in by_name and str(by_name[ref_name]["container"]).endswith(".obb"):
                    direct_refs.append(ref_name)
                    if ref_name not in seen:
                        todo.append(ref_name)
                elif ref_name:
                    unresolved.add(ref_name)
            row = by_name[name]
            records.append({
                "name": name,
                "bytes": int(row["bytes"]),
                "sha256": str(row["sha256"]),
                "container": str(row["container"]),
                "parts": list(row["parts"]),
                "direct_serialized_refs": sorted(set(direct_refs)),
            })
    records.sort(key=lambda row: (0 if row["name"] == root else 1, row["name"]))
    return {
        "format_version": 1,
        "identity": identity,
        "root_source_unit": root,
        "files": records,
        "file_count": len(records),
        "total_uncompressed_bytes": sum(int(row["bytes"]) for row in records),
        "unresolved_external_basenames": sorted(unresolved),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--summary", required=True, type=Path)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--cache", required=True, type=Path)
    parser.add_argument("--root", required=True)
    parser.add_argument("--identity")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    result = build_closure(args.summary, args.archive, args.cache, args.root, args.identity or args.root)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps({
        "identity": result["identity"],
        "root_source_unit": result["root_source_unit"],
        "file_count": result["file_count"],
        "total_uncompressed_bytes": result["total_uncompressed_bytes"],
        "unresolved_external_basenames": result["unresolved_external_basenames"],
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
