#!/usr/bin/env python3
"""Compile explicit Jamaica OSM street-lamp points into a visual-only tile layer.

Only ``highway=street_lamp`` nodes are geographic authority. This compiler does
not infer lamps from road class, spacing, population density, recovered source
game props, or any other heuristic. Recovered art may decorate these records
only after that art passes its separate Beta 1 recovery and render acceptance.
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


def _normal(value) -> str:
    return str(value or "").strip().lower().replace(" ", "_")


def _is_street_lamp(tags: dict) -> bool:
    return _normal(tags.get("highway")) == "street_lamp"


def _finite_height(tags: dict):
    raw = str(tags.get("height", "")).strip().lower()
    for suffix in ("metres", "meters", "meter", "metre", "m"):
        if raw.endswith(suffix):
            raw = raw[:-len(suffix)].strip()
            break
    if not raw:
        return None
    try:
        value = float(raw)
    except ValueError:
        return None
    if not math.isfinite(value) or value <= 0.0 or value > 40.0:
        return None
    return round(value, 3)


def _hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _read_osm_street_lamps(path: Path) -> list[dict]:
    import osmium

    class StreetLamps(osmium.SimpleHandler):
        def __init__(self):
            super().__init__()
            self.features = []

        def node(self, node):
            tags = dict(node.tags)
            if not _is_street_lamp(tags):
                return
            try:
                lon, lat = node.location.lon, node.location.lat
            except osmium.InvalidLocationError as exc:
                raise ValueError(f"Missing location in OSM street lamp node {node.id}") from exc
            self.features.append({
                "type": "Feature",
                "id": f"n{node.id}",
                "properties": tags,
                "geometry": {"type": "Point", "coordinates": [lon, lat]},
            })

    handler = StreetLamps()
    handler.apply_file(str(path), locations=True)
    return handler.features


def extract_streetlights(features, transformer, origin, tile_size: float) -> dict:
    if tile_size <= 0 or not math.isfinite(tile_size):
        raise ValueError("tile_size must be finite and positive")

    tiles = defaultdict(list)
    feature_ids = set()
    mount_counts = Counter()
    support_counts = Counter()
    bounds = [float("inf"), float("inf"), float("-inf"), float("-inf")]

    for feature in features:
        tags = dict(feature.get("properties") or {})
        if isinstance(tags.get("tags"), dict):
            tags.update(tags["tags"])
        if not _is_street_lamp(tags):
            continue
        geometry = feature.get("geometry") or {}
        if geometry.get("type") != "Point":
            continue
        coordinate = geometry.get("coordinates") or []
        if len(coordinate) < 2:
            continue

        source_id = str(feature.get("id") or tags.get("@id") or "")
        if not source_id:
            source_id = "street-lamp-" + hashlib.sha1(repr((coordinate, sorted(tags.items()))).encode()).hexdigest()[:20]
        if source_id in feature_ids:
            raise ValueError(f"Duplicate street lamp source id: {source_id}")

        e, n = transformer.transform(float(coordinate[0]), float(coordinate[1]))
        x, z = round(e - origin[0], 3), round(origin[1] - n, 3)
        if not math.isfinite(x) or not math.isfinite(z):
            raise ValueError(f"Non-finite street lamp coordinate in {source_id}")
        tx, tz = math.floor(x / tile_size), math.floor(z / tile_size)

        mount = _normal(tags.get("lamp_mount")) or "unspecified"
        support = _normal(tags.get("support")) or "unspecified"
        record = {
            "source_node": source_id,
            "position": [x, z],
            "highway": "street_lamp",
            "lamp_mount": mount,
            "support": support,
        }
        height_m = _finite_height(tags)
        if height_m is not None:
            record["height_m"] = height_m
        for source_key, output_key in (
            ("lamp_type", "lamp_type"),
            ("light:colour", "light_colour"),
            ("direction", "direction"),
            ("manufacturer", "manufacturer"),
        ):
            value = str(tags.get(source_key, "")).strip()
            if value:
                record[output_key] = value

        tiles[(tx, tz)].append(record)
        feature_ids.add(source_id)
        mount_counts[mount] += 1
        support_counts[support] += 1
        bounds[0] = min(bounds[0], x); bounds[1] = min(bounds[1], z)
        bounds[2] = max(bounds[2], x); bounds[3] = max(bounds[3], z)

    for records in tiles.values():
        records.sort(key=lambda item: item["source_node"])
    if not feature_ids:
        bounds = []
    return {
        "tiles": dict(tiles),
        "stats": {
            "features": len(feature_ids),
            "tiles": len(tiles),
            "by_lamp_mount": dict(sorted(mount_counts.items())),
            "by_support": dict(sorted(support_counts.items())),
        },
        "bounds": [round(value, 3) for value in bounds] if bounds else [],
    }


def write_dataset(input_path: Path, output_dir: Path, tile_size: float) -> dict:
    if input_path.suffix == ".pbf":
        features = _read_osm_street_lamps(input_path)
    else:
        features = json.loads(input_path.read_text(encoding="utf-8")).get("features", [])
    transformer = Transformer.from_crs(CRS_SOURCE, CRS_TARGET, always_xy=True)
    origin_e, origin_n = transformer.transform(ORIGIN_LON, ORIGIN_LAT)
    result = extract_streetlights(features, transformer, (origin_e, origin_n), tile_size)

    staging = output_dir.with_name(output_dir.name + ".staging")
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    tile_entries = []
    for (tx, tz), records in sorted(result["tiles"].items()):
        filename = f"tile_{tx}_{tz}.json"
        (staging / filename).write_text(
            json.dumps({"tile": [tx, tz], "street_lights": records}, separators=(",", ":")),
            encoding="utf-8",
        )
        tile_entries.append({"x": tx, "z": tz, "file": filename, "records": len(records)})

    manifest = {
        "format": 1,
        "purpose": "visual-only explicit OSM highway=street_lamp points; OSM remains geographic authority",
        "source": "OpenStreetMap / Geofabrik Jamaica extract",
        "source_sha256": _hash_file(input_path),
        "attribution": "© OpenStreetMap contributors — https://www.openstreetmap.org/copyright (ODbL)",
        "crs": CRS_TARGET,
        "axis": "X=east, Z=south, metres",
        "tile_size": tile_size,
        "placement_rule": "explicit highway=street_lamp nodes only; no inferred spacing or recovered-art placement",
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
    print("YARDMAN_STREETLIGHTS_BUILD PASS features=%d tiles=%d" % (stats["features"], stats["tiles"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
