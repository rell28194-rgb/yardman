#!/usr/bin/env python3
"""Compile explicit Jamaica OSM bus-stop point authority into world tiles.

Accepted geography is deliberately narrow: OSM nodes tagged ``highway=bus_stop``
or nodes tagged ``public_transport=platform`` with explicit ``bus=yes``. Shelter,
bench, operator and naming metadata are preserved only when stated by the source.
No stops, shelters or benches are inferred from road class, route proximity, or
recovered source-game transforms.
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

TRUE_VALUES = {"yes", "true", "1", "designated"}


def _normal(value) -> str:
    return str(value or "").strip().lower().replace(" ", "_")


def _is_bus_stop(tags: dict) -> bool:
    if _normal(tags.get("highway")) == "bus_stop":
        return True
    return _normal(tags.get("public_transport")) == "platform" and _normal(tags.get("bus")) in TRUE_VALUES


def _hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _read_osm_bus_stops(path: Path) -> list[dict]:
    import osmium

    class BusStops(osmium.SimpleHandler):
        def __init__(self):
            super().__init__()
            self.features = []

        def node(self, node):
            tags = dict(node.tags)
            if not _is_bus_stop(tags):
                return
            if not node.location.valid():
                raise ValueError(f"Missing location in OSM bus-stop node {node.id}")
            self.features.append({
                "type": "Feature",
                "id": f"n{node.id}",
                "properties": tags,
                "geometry": {"type": "Point", "coordinates": [node.location.lon, node.location.lat]},
            })

    handler = BusStops()
    handler.apply_file(str(path), locations=False)
    return handler.features


def _source_kind(tags: dict) -> str:
    if _normal(tags.get("highway")) == "bus_stop":
        return "highway=bus_stop"
    return "public_transport=platform+bus"


def extract_bus_stops(features, transformer, origin, tile_size: float) -> dict:
    if tile_size <= 0 or not math.isfinite(tile_size):
        raise ValueError("tile_size must be finite and positive")

    tiles = defaultdict(list)
    seen_ids = set()
    kind_counts = Counter()
    shelter_counts = Counter()
    bench_counts = Counter()
    bounds = [float("inf"), float("inf"), float("-inf"), float("-inf")]

    for feature in features:
        tags = dict(feature.get("properties") or {})
        if isinstance(tags.get("tags"), dict):
            tags.update(tags["tags"])
        if not _is_bus_stop(tags):
            continue
        geometry = feature.get("geometry") or {}
        if geometry.get("type") != "Point":
            continue
        coordinates = geometry.get("coordinates") or []
        if len(coordinates) < 2:
            continue
        source_id = str(feature.get("id") or tags.get("@id") or "")
        if not source_id:
            source_id = "bus-stop-" + hashlib.sha1(repr((coordinates, sorted(tags.items()))).encode()).hexdigest()[:20]
        if source_id in seen_ids:
            raise ValueError(f"Duplicate bus-stop source id: {source_id}")
        seen_ids.add(source_id)

        e, n = transformer.transform(float(coordinates[0]), float(coordinates[1]))
        x = round(e - origin[0], 3)
        z = round(origin[1] - n, 3)
        if not math.isfinite(x) or not math.isfinite(z):
            raise ValueError(f"Non-finite bus-stop coordinate in {source_id}")
        tx = math.floor(x / tile_size)
        tz = math.floor(z / tile_size)
        kind = _source_kind(tags)
        shelter = _normal(tags.get("shelter")) or "unspecified"
        bench = _normal(tags.get("bench")) or "unspecified"
        record = {
            "source_node": source_id,
            "position": [x, z],
            "kind": kind,
            "shelter": shelter,
            "bench": bench,
        }
        for source_key, output_key in (
            ("name", "name"),
            ("operator", "operator"),
            ("network", "network"),
            ("ref", "ref"),
            ("route_ref", "route_ref"),
            ("wheelchair", "wheelchair"),
        ):
            value = str(tags.get(source_key, "")).strip()
            if value:
                record[output_key] = value
        tiles[(tx, tz)].append(record)
        kind_counts[kind] += 1
        shelter_counts[shelter] += 1
        bench_counts[bench] += 1
        bounds[0] = min(bounds[0], x); bounds[1] = min(bounds[1], z)
        bounds[2] = max(bounds[2], x); bounds[3] = max(bounds[3], z)

    for records in tiles.values():
        records.sort(key=lambda item: item["source_node"])
    if not seen_ids:
        bounds = []
    return {
        "tiles": dict(tiles),
        "stats": {
            "features": len(seen_ids),
            "tiles": len(tiles),
            "by_kind": dict(sorted(kind_counts.items())),
            "by_shelter": dict(sorted(shelter_counts.items())),
            "by_bench": dict(sorted(bench_counts.items())),
        },
        "bounds": [round(value, 3) for value in bounds] if bounds else [],
    }


def write_dataset(input_path: Path, output_dir: Path, tile_size: float) -> dict:
    if input_path.suffix == ".pbf":
        features = _read_osm_bus_stops(input_path)
    else:
        features = json.loads(input_path.read_text(encoding="utf-8")).get("features", [])
    transformer = Transformer.from_crs(CRS_SOURCE, CRS_TARGET, always_xy=True)
    origin_e, origin_n = transformer.transform(ORIGIN_LON, ORIGIN_LAT)
    result = extract_bus_stops(features, transformer, (origin_e, origin_n), tile_size)

    staging = output_dir.with_name(output_dir.name + ".staging")
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    tile_entries = []
    for (tx, tz), records in sorted(result["tiles"].items()):
        filename = f"tile_{tx}_{tz}.json"
        (staging / filename).write_text(
            json.dumps({"tile": [tx, tz], "bus_stops": records}, separators=(",", ":")),
            encoding="utf-8",
        )
        tile_entries.append({"x": tx, "z": tz, "file": filename, "records": len(records)})

    manifest = {
        "format": 1,
        "purpose": "visual-only explicit OSM bus-stop point authority; OSM remains geographic authority",
        "source": "OpenStreetMap / Geofabrik Jamaica extract",
        "source_sha256": _hash_file(input_path),
        "attribution": "© OpenStreetMap contributors — https://www.openstreetmap.org/copyright (ODbL)",
        "crs": CRS_TARGET,
        "axis": "X=east, Z=south, metres",
        "tile_size": tile_size,
        "placement_rule": "explicit highway=bus_stop nodes or public_transport=platform nodes with bus=yes only; no inferred stops, shelters or benches",
        "shelter_rule": "shelter art requires source shelter=yes/true/1/designated; unspecified stops remain unsheltered",
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
    print("YARDMAN_BUS_STOPS_BUILD PASS features=%d tiles=%d" % (stats["features"], stats["tiles"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
