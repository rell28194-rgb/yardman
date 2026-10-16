#!/usr/bin/env python3
"""Compile registered Jamaica OSM fence geometry into a visual-only tile layer.

All ``barrier=fence`` ways are retained so geographic authority stays with the
Jamaica OSM extract. ``wire_compatible`` is deliberately strict: recovered
chain-link art may decorate only ways explicitly tagged as chain-link/wire or
metal/steel, never an untyped fence merely because a private model exists.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import shutil
from collections import Counter, defaultdict
from pathlib import Path

from pyproj import Transformer

from build_jamaica_roads import CRS_SOURCE, CRS_TARGET, ORIGIN_LAT, ORIGIN_LON
from road_graph import split_segment

WIRE_FENCE_TYPES = {
    "chain_link", "chainlink", "chain-link", "wire", "wire_mesh",
    "metal", "barbed_wire", "barbed-wire",
}
WIRE_MATERIALS = {"metal", "steel", "wire", "galvanized_steel", "galvanised_steel"}
TRUE_VALUES = {"yes", "true", "1"}


def _normal(value) -> str:
    return str(value or "").strip().lower().replace(" ", "_")


def _is_fence(tags: dict) -> bool:
    return _normal(tags.get("barrier")) == "fence"


def _wire_compatible(tags: dict) -> bool:
    fence_type = _normal(tags.get("fence_type"))
    material = _normal(tags.get("material"))
    barbed = _normal(tags.get("barbed_wire"))
    return fence_type in WIRE_FENCE_TYPES or material in WIRE_MATERIALS or barbed in TRUE_VALUES


def _finite_height(tags: dict):
    raw = str(tags.get("height", "")).strip().lower().replace("metres", "").replace("meters", "").replace("m", "").strip()
    if not raw:
        return None
    try:
        value = float(raw)
    except ValueError:
        return None
    if not math.isfinite(value) or value <= 0.0 or value > 20.0:
        return None
    return round(value, 3)


def _hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _read_osm_fences(path: Path) -> list[dict]:
    """Read barrier=fence ways directly; the road reader intentionally cannot."""
    import osmium

    class Fences(osmium.SimpleHandler):
        def __init__(self):
            super().__init__()
            self.features = []

        def way(self, way):
            tags = dict(way.tags)
            if not _is_fence(tags):
                return
            try:
                coordinates = [[node.lon, node.lat] for node in way.nodes]
            except osmium.InvalidLocationError as exc:
                raise ValueError(f"Missing location in OSM fence way {way.id}") from exc
            self.features.append({
                "type": "Feature",
                "id": f"w{way.id}",
                "properties": tags,
                "geometry": {"type": "LineString", "coordinates": coordinates},
            })

    handler = Fences()
    handler.apply_file(str(path), locations=True)
    return handler.features


def extract_fences(features, transformer, origin, tile_size: float) -> dict:
    if tile_size <= 0 or not math.isfinite(tile_size):
        raise ValueError("tile_size must be finite and positive")
    tiles = defaultdict(list)
    feature_ids = set()
    source_segments = 0
    tile_pieces = 0
    wire_features = set()
    type_counts = Counter()
    material_counts = Counter()
    bounds = [float("inf"), float("inf"), float("-inf"), float("-inf")]

    for feature in features:
        tags = dict(feature.get("properties") or {})
        if isinstance(tags.get("tags"), dict):
            tags.update(tags["tags"])
        if not _is_fence(tags):
            continue
        geometry = feature.get("geometry") or {}
        lines = ([geometry.get("coordinates", [])] if geometry.get("type") == "LineString"
                 else geometry.get("coordinates", []) if geometry.get("type") == "MultiLineString" else [])
        source_id = str(feature.get("id") or tags.get("@id") or "")
        if not source_id:
            source_id = "fence-" + hashlib.sha1(repr((lines, sorted(tags.items()))).encode()).hexdigest()[:20]
        if source_id in feature_ids:
            raise ValueError(f"Duplicate fence source id: {source_id}")
        fence_type = _normal(tags.get("fence_type")) or "unspecified"
        material = _normal(tags.get("material")) or "unspecified"
        compatible = _wire_compatible(tags)
        height_m = _finite_height(tags)
        had_segment = False

        for line_index, line in enumerate(lines):
            if len(line) < 2:
                continue
            points = []
            for coordinate in line:
                e, n = transformer.transform(float(coordinate[0]), float(coordinate[1]))
                point = (round(e - origin[0], 3), 0.0, round(origin[1] - n, 3))
                if not all(math.isfinite(value) for value in point):
                    raise ValueError(f"Non-finite fence coordinate in {source_id}")
                points.append(point)
                bounds[0] = min(bounds[0], point[0]); bounds[1] = min(bounds[1], point[2])
                bounds[2] = max(bounds[2], point[0]); bounds[3] = max(bounds[3], point[2])
            for segment_index, (a, b) in enumerate(zip(points, points[1:])):
                if math.dist(a, b) < 0.05:
                    continue
                source_segments += 1
                had_segment = True
                for (tx, tz), start, end in split_segment(a, b, tile_size):
                    record = {
                        "source_way": source_id,
                        "line": line_index,
                        "segment": segment_index,
                        "start": [round(start[0], 3), round(start[2], 3)],
                        "end": [round(end[0], 3), round(end[2], 3)],
                        "barrier": "fence",
                        "fence_type": fence_type,
                        "material": material,
                        "wire_compatible": compatible,
                    }
                    if height_m is not None:
                        record["height_m"] = height_m
                    tiles[(tx, tz)].append(record)
                    tile_pieces += 1
        if had_segment:
            feature_ids.add(source_id)
            if compatible:
                wire_features.add(source_id)
            type_counts[fence_type] += 1
            material_counts[material] += 1

    if not feature_ids:
        bounds = []
    for records in tiles.values():
        records.sort(key=lambda item: (item["source_way"], item["line"], item["segment"], item["start"]))
    return {
        "tiles": dict(tiles),
        "stats": {
            "features": len(feature_ids),
            "wire_compatible_features": len(wire_features),
            "source_segments": source_segments,
            "tile_pieces": tile_pieces,
            "tiles": len(tiles),
            "by_fence_type": dict(sorted(type_counts.items())),
            "by_material": dict(sorted(material_counts.items())),
        },
        "bounds": [round(value, 3) for value in bounds] if bounds else [],
    }


def write_dataset(input_path: Path, output_dir: Path, tile_size: float) -> dict:
    features = _read_osm_fences(input_path) if input_path.suffix == ".pbf" else json.loads(input_path.read_text(encoding="utf-8")).get("features", [])
    transformer = Transformer.from_crs(CRS_SOURCE, CRS_TARGET, always_xy=True)
    origin_e, origin_n = transformer.transform(ORIGIN_LON, ORIGIN_LAT)
    result = extract_fences(features, transformer, (origin_e, origin_n), tile_size)
    staging = output_dir.with_name(output_dir.name + ".staging")
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    tile_entries = []
    for (tx, tz), records in sorted(result["tiles"].items()):
        filename = f"tile_{tx}_{tz}.json"
        (staging / filename).write_text(json.dumps({"tile": [tx, tz], "fences": records}, separators=(",", ":")), encoding="utf-8")
        tile_entries.append({"x": tx, "z": tz, "file": filename, "records": len(records)})
    manifest = {
        "format": 1,
        "purpose": "visual-only OSM barrier=fence geometry; OSM remains geographic authority",
        "source": "OpenStreetMap / Geofabrik Jamaica extract",
        "source_sha256": _hash_file(input_path),
        "attribution": "© OpenStreetMap contributors — https://www.openstreetmap.org/copyright (ODbL)",
        "crs": CRS_TARGET,
        "axis": "X=east, Z=south, metres",
        "tile_size": tile_size,
        "wire_compatibility_rule": "explicit chain-link/wire/metal/steel/barbed-wire tags only; untyped fences are not assigned recovered chain-link art",
        "bounds": result["bounds"],
        "stats": result["stats"],
        "tiles": tile_entries,
    }
    (staging / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True), encoding="utf-8")
    if output_dir.exists():
        shutil.rmtree(output_dir)
    staging.replace(output_dir)
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("--tile-size", type=float, default=4096.0)
    args = parser.parse_args()
    manifest = write_dataset(args.input, args.output_dir, args.tile_size)
    stats = manifest["stats"]
    print("YARDMAN_FENCES_BUILD PASS features=%d wire=%d source_segments=%d tile_pieces=%d tiles=%d" %
          (stats["features"], stats["wire_compatible_features"], stats["source_segments"], stats["tile_pieces"], stats["tiles"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
