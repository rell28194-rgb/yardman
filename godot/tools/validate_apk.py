#!/usr/bin/env python3
"""Fail if an Android export omitted national data or shipped the wrong ABI."""
import argparse
import hashlib
import json
import struct
import zipfile
from pathlib import Path
from validate_road_structures import validate_payloads


def validate(apk: Path, source_manifest: Path, terrain_manifest: Path | None = None,
             coast_manifest: Path | None = None, buildings_manifest: Path | None = None) -> dict:
    source = json.loads(source_manifest.read_text())
    roadwork_proof = {"roadwork_features": 0, "roadwork_tiles": 0}
    fence_proof = {"fence_features": 0, "wire_fence_features": 0, "fence_tiles": 0}
    bus_stop_proof = {"bus_stop_features": 0, "bus_stop_tiles": 0}
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
        roadwork_source_path = source_manifest.parent / "roadworks" / "manifest.json"
        if roadwork_source_path.is_file():
            roadwork_name = "assets/data/roads/roadworks/manifest.json"
            if roadwork_name not in names:
                raise ValueError("Packaged Jamaica roadwork metadata is missing")
            expected_roadworks = json.loads(roadwork_source_path.read_text())
            roadworks = json.loads(archive.read(roadwork_name))
            if roadworks != expected_roadworks:
                raise ValueError("Packaged roadwork metadata differs from compiled Jamaica source")
            if roadworks.get("crs") != manifest.get("crs") or roadworks.get("source_sha256") != manifest.get("source_sha256"):
                raise ValueError("Roadwork metadata source registration differs from roads")
            if roadworks.get("purpose") != "visual-only OSM-tagged roadworks; never navigation authority":
                raise ValueError("Roadwork metadata lost its visual-only authority boundary")
            for tile in roadworks.get("tiles", []):
                name = "assets/data/roads/roadworks/" + str(tile.get("file", ""))
                if name not in names:
                    raise ValueError("A Jamaica roadwork tile was omitted from the APK: " + name)
            roadwork_proof = {
                "roadwork_features": int(roadworks.get("stats", {}).get("features", 0)),
                "roadwork_tiles": len(roadworks.get("tiles", [])),
            }
        fence_source_path = source_manifest.parent / "fences" / "manifest.json"
        if fence_source_path.is_file():
            fence_name = "assets/data/roads/fences/manifest.json"
            if fence_name not in names:
                raise ValueError("Packaged Jamaica fence metadata is missing")
            expected_fences = json.loads(fence_source_path.read_text())
            fences = json.loads(archive.read(fence_name))
            if fences != expected_fences:
                raise ValueError("Packaged fence metadata differs from compiled Jamaica source")
            if fences.get("crs") != manifest.get("crs") or fences.get("source_sha256") != manifest.get("source_sha256"):
                raise ValueError("Fence metadata source registration differs from roads")
            if fences.get("purpose") != "visual-only OSM barrier=fence geometry; OSM remains geographic authority":
                raise ValueError("Fence metadata lost its visual-only authority boundary")
            expected_rule = "explicit chain-link/wire/metal/steel/barbed-wire tags only; untyped fences are not assigned recovered chain-link art"
            if fences.get("wire_compatibility_rule") != expected_rule:
                raise ValueError("Fence metadata lost its strict recovered-art compatibility rule")
            for tile in fences.get("tiles", []):
                name = "assets/data/roads/fences/" + str(tile.get("file", ""))
                if name not in names:
                    raise ValueError("A Jamaica fence tile was omitted from the APK: " + name)
            fence_proof = {
                "fence_features": int(fences.get("stats", {}).get("features", 0)),
                "wire_fence_features": int(fences.get("stats", {}).get("wire_compatible_features", 0)),
                "fence_tiles": len(fences.get("tiles", [])),
            }
        bus_stop_source_path = source_manifest.parent / "bus_stops" / "manifest.json"
        if bus_stop_source_path.is_file():
            bus_stop_name = "assets/data/roads/bus_stops/manifest.json"
            if bus_stop_name not in names:
                raise ValueError("Packaged Jamaica bus-stop authority is missing")
            expected_bus_stops = json.loads(bus_stop_source_path.read_text())
            bus_stops = json.loads(archive.read(bus_stop_name))
            if bus_stops != expected_bus_stops:
                raise ValueError("Packaged bus-stop metadata differs from compiled Jamaica source")
            if bus_stops.get("crs") != manifest.get("crs") or bus_stops.get("source_sha256") != manifest.get("source_sha256"):
                raise ValueError("Bus-stop source registration differs from roads")
            if bus_stops.get("purpose") != "visual-only explicit OSM bus-stop point authority; OSM remains geographic authority":
                raise ValueError("Bus-stop metadata lost its explicit geographic authority boundary")
            expected_rule = "explicit highway=bus_stop nodes or public_transport=platform nodes with bus=yes only; no inferred stops, shelters or benches"
            if bus_stops.get("placement_rule") != expected_rule:
                raise ValueError("Bus-stop metadata lost its explicit-only placement rule")
            counted_bus_stops = 0
            seen_bus_nodes = set()
            for tile in bus_stops.get("tiles", []):
                filename = str(tile.get("file", ""))
                name = "assets/data/roads/bus_stops/" + filename
                if name not in names:
                    raise ValueError("A Jamaica bus-stop tile was omitted from the APK: " + name)
                payload = json.loads(archive.read(name))
                if payload.get("tile") != [tile.get("x"), tile.get("z")]:
                    raise ValueError("Bus-stop tile coordinates disagree with manifest: " + filename)
                records = payload.get("bus_stops", [])
                if len(records) != int(tile.get("records", -1)):
                    raise ValueError("Bus-stop tile record count disagrees with manifest: " + filename)
                for record in records:
                    source_node = str(record.get("source_node", ""))
                    position = record.get("position", [])
                    if not source_node or source_node in seen_bus_nodes:
                        raise ValueError("Missing or duplicate Jamaica bus-stop source node: " + source_node)
                    if not isinstance(position, list) or len(position) < 2:
                        raise ValueError("Invalid Jamaica bus-stop position: " + source_node)
                    seen_bus_nodes.add(source_node)
                    counted_bus_stops += 1
            expected_count = int(bus_stops.get("stats", {}).get("features", -1))
            if counted_bus_stops != expected_count:
                raise ValueError("Bus-stop feature count differs from manifest")
            bus_stop_proof = {
                "bus_stop_features": counted_bus_stops,
                "bus_stop_tiles": len(bus_stops.get("tiles", [])),
            }
        structure_proof = {}
        if manifest.get("structures"):
            def read_structure(relative):
                if Path(relative).is_absolute() or ".." in Path(relative).parts:
                    raise ValueError("Invalid packaged road structure path")
                name = "assets/data/roads/" + relative
                if name not in names:
                    raise ValueError("Missing APK road structure resource: " + relative)
                actual = json.loads(archive.read(name))
                expected_path = source_manifest.parent / relative
                if not expected_path.is_file() or actual != json.loads(expected_path.read_text()):
                    raise ValueError("Packaged road structure differs from validated source: " + relative)
                return actual
            structure_proof = validate_payloads(manifest, read_structure)
        if terrain_manifest is not None:
            expected_terrain = json.loads(terrain_manifest.read_text())
            terrain = json.loads(archive.read("assets/data/terrain/manifest.json"))
            if terrain != expected_terrain:
                raise ValueError("Packaged terrain manifest differs from compiled terrain")
            expected_size = terrain["resolution"] ** 2 * 4
            for tile in terrain["tiles"]:
                name = "assets/data/terrain/" + tile["file"]
                if name not in names or archive.getinfo(name).file_size != expected_size:
                    raise ValueError("Terrain sample file is absent or truncated: " + name)
            overview = terrain["overview"]
            overview_name = "assets/data/terrain/" + overview["file"]
            if archive.getinfo(overview_name).file_size != overview["width"] * overview["depth"] * 4:
                raise ValueError("Terrain overview is truncated")
        if manifest.get("graph"):
            node_files = [n for n in names if n.startswith("assets/data/roads/graph/nodes_")]
            edge_files = [n for n in names if n.startswith("assets/data/roads/graph/edges_")]
            if len(node_files) != 256 or len(edge_files) != 256:
                raise ValueError("National graph partitions were omitted from the APK")
        if coast_manifest is not None:
            coast = json.loads(archive.read("assets/data/coast/manifest.json"))
            if coast != json.loads(coast_manifest.read_text()):
                raise ValueError("Packaged coastline differs from the tested data")
            if coast["crs"] != manifest["crs"] or coast["source_sha256"] != manifest["source_sha256"]:
                raise ValueError("Road and coastline source registration differ")
            if terrain_manifest is not None:
                if coast["terrain_manifest_sha256"] != hashlib.sha256(archive.read("assets/data/terrain/manifest.json")).hexdigest():
                    raise ValueError("Coastline was compiled against different elevation data")
                if {(t["x"], t["z"]) for t in coast["tiles"]} != {(t["x"], t["z"]) for t in terrain["tiles"]}:
                    raise ValueError("Coastline coverage omits a terrain tile")
            for tile in coast["tiles"]:
                for layer, stride in (("mask", 1), ("land", 36), ("water", 48), ("beach", 36)):
                    name = "assets/data/coast/" + tile[layer]
                    expected = (terrain["resolution"] - 1) ** 2 if layer == "mask" else tile[layer + "_triangles"] * stride
                    if name not in names or archive.getinfo(name).file_size != expected:
                        raise ValueError("Coast payload omitted or truncated: " + name)
                    if layer == "mask" and set(archive.read(name)) - {0, 1, 2}:
                        raise ValueError("Invalid shoreline mask: " + name)
            overview = coast["overview"]
            for layer, stride in (("mask", 1), ("land", 36), ("water", 48)):
                name = "assets/data/coast/" + overview[layer]
                size = archive.getinfo(name).file_size
                if layer == "mask" and size != (overview["width"] - 1) * (overview["depth"] - 1):
                    raise ValueError("Coast overview mask is truncated")
                if layer != "mask" and size % stride:
                    raise ValueError("Coast overview geometry is truncated")
        if buildings_manifest is not None:
            buildings = json.loads(archive.read("assets/data/buildings/manifest.json"))
            if buildings != json.loads(buildings_manifest.read_text()):
                raise ValueError("Packaged building footprints differ from compiled data")
            if buildings["crs"] != manifest["crs"] or buildings["source_sha256"] != manifest["source_sha256"]:
                raise ValueError("Building source registration differs from roads")
            for tile in buildings["tiles"]:
                name = "assets/data/buildings/" + tile["file"]
                payload = archive.read(name)
                if len(payload) < 8 or payload[:4] != b"YMB1":
                    raise ValueError("Building tile header missing: " + name)
                count = struct.unpack_from("<I", payload, 4)[0]
                if count > 256 or len(payload) < 8 + count * 12:
                    raise ValueError("Building tile cell index is truncated: " + name)
                seen = set()
                for index in range(count):
                    x, z, offset, size = struct.unpack_from("<HHII", payload, 8 + index * 12)
                    if x >= 16 or z >= 16 or (x, z) in seen or offset < 8 + count * 12 or offset + size > len(payload):
                        raise ValueError("Invalid building cell address/range: " + name)
                    seen.add((x, z))
        abis = {n.split("/")[1] for n in names if n.startswith("lib/") and n.endswith(".so")}
        if abis != {"arm64-v8a"}:
            raise ValueError("Unexpected Android architectures: " + repr(abis))
        for native in [n for n in names if n.startswith("lib/") and n.endswith(".so")]:
            header = archive.read(native)[:20]
            if header[:4] != b"\x7fELF" or struct.unpack_from("<H", header, 18)[0] != 183:
                raise ValueError("Native library is not AArch64: " + native)
    return {"apk_bytes": apk.stat().st_size, "road_tiles": len(source["tiles"]),
            "coast_tiles": len(coast["tiles"]) if coast_manifest else 0,
            "building_tiles": len(buildings["tiles"]) if buildings_manifest else 0,
            "graph_edges": source["stats"].get("graph_edges", 0), "abis": sorted(abis),
            **roadwork_proof, **fence_proof, **bus_stop_proof, **structure_proof}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("apk", type=Path)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--terrain-manifest", type=Path)
    parser.add_argument("--coast-manifest", type=Path)
    parser.add_argument("--buildings-manifest", type=Path)
    arguments = parser.parse_args()
    print("YARDMAN_APK_VALIDATION_PASS", json.dumps(validate(arguments.apk, arguments.manifest, arguments.terrain_manifest,
                                                           arguments.coast_manifest, arguments.buildings_manifest)))