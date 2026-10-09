#!/usr/bin/env python3
"""Fail if an Android export omitted national data or shipped the wrong ABI."""
import argparse
import json
import struct
import zipfile
from pathlib import Path


def validate(apk: Path, source_manifest: Path) -> dict:
    source = json.loads(source_manifest.read_text())
    with zipfile.ZipFile(apk) as archive:
        corrupt = archive.testzip()
        if corrupt:
            raise ValueError("Corrupt APK entry: " + corrupt)
        names = set(archive.namelist())
        for required in ("AndroidManifest.xml", "resources.arsc", "assets/data/roads/manifest.json",
                         "lib/arm64-v8a/libgodot_android.so"):
            if required not in names:
                raise ValueError("Missing APK resource: " + required)
        manifest = json.loads(archive.read("assets/data/roads/manifest.json"))
        if manifest != source:
            raise ValueError("Packaged national data does not match the validated source manifest")
        for tile in manifest["tiles"]:
            if "assets/data/roads/" + tile["file"] not in names:
                raise ValueError("A road tile was omitted from the APK")
        if manifest.get("graph"):
            node_files = [n for n in names if n.startswith("assets/data/roads/graph/nodes_")]
            edge_files = [n for n in names if n.startswith("assets/data/roads/graph/edges_")]
            if len(node_files) != 256 or len(edge_files) != 256:
                raise ValueError("National graph partitions were omitted from the APK")
        abis = {n.split("/")[1] for n in names if n.startswith("lib/") and n.endswith(".so")}
        if abis != {"arm64-v8a"}:
            raise ValueError("Unexpected Android architectures: " + repr(abis))
        for native in [n for n in names if n.startswith("lib/") and n.endswith(".so")]:
            header = archive.read(native)[:20]
            if header[:4] != b"\x7fELF" or struct.unpack_from("<H", header, 18)[0] != 183:
                raise ValueError("Native library is not AArch64: " + native)
    return {"apk_bytes": apk.stat().st_size, "road_tiles": len(source["tiles"]),
            "graph_edges": source["stats"].get("graph_edges", 0), "abis": sorted(abis)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("apk", type=Path)
    parser.add_argument("manifest", type=Path)
    arguments = parser.parse_args()
    print("YARDMAN_APK_VALIDATION_PASS", json.dumps(validate(arguments.apk, arguments.manifest)))
