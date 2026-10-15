#!/usr/bin/env python3
"""Compile explicit Jamaica OSM drainage evidence into deterministic tile metadata.

This layer is deliberately conservative. It records mapped ditches/drains and
explicit culverts so road-earthworks code can respect real drainage evidence.
Generic streams and rivers are not promoted into road drainage unless the OSM
feature explicitly identifies a culvert. This dataset is evidence for engineering
placement; it never changes the national road graph or Jamaica terrain authority.
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

_FALSE = {"", "no", "0", "false", "none"}
_DRAIN_WATERWAYS = {"ditch", "drain"}
_CULVERT_WATERWAYS = {"ditch", "drain", "stream", "canal", "river"}


def _normal(value) -> str:
    return str(value or "").strip().lower().replace(" ", "_")


def _truthy(value) -> bool:
    return _normal(value) not in _FALSE


def drainage_kind(tags: dict) -> str | None:
    waterway = _normal(tags.get("waterway"))
    tunnel = _normal(tags.get("tunnel"))
    man_made = _normal(tags.get("man_made"))
    explicit_culvert = tunnel == "culvert" or man_made == "culvert" or _truthy(tags.get("culvert"))
    if explicit_culvert and (waterway in _CULVERT_WATERWAYS or man_made == "culvert"):
        return "culvert"
    if waterway in _DRAIN_WATERWAYS:
        return waterway
    return None


def _finite_measure(tags: dict):
    for key in ("width", "diameter"):
        raw = str(tags.get(key, "")).strip().lower()
        for suffix in ("metres", "meters", "meter", "metre", "m"):
            if raw.endswith(suffix):
                raw = raw[:-len(suffix)].strip()
                break
        if not raw:
            continue
        try:
            value = float(raw)
        except ValueError:
            continue
        if math.isfinite(value) and 0.05 <= value <= 50.0:
            return round(value, 3), key
    return None, None


def _hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _read_osm_drainage(path: Path) -> list[dict]:
    import osmium

    class Drainage(osmium.SimpleHandler):
        def __init__(self):
            super().__init__()
            self.features = []

        def way(self, way):
            tags = dict(way.tags)
            if drainage_kind(tags) is None:
                return
            try:
                coordinates = [[node.lon, node.lat] for node in way.nodes]
            except osmium.InvalidLocationError as exc:
                raise ValueError(f"Missing location in OSM drainage way {way.id}") from exc
            self.features.append({
                "type": "Feature",
                "id": f"w{way.id}",
                "properties": tags,
                "geometry": {"type": "LineString", "coordinates": coordinates},
            })

    handler = Drainage()
    handler.apply_file(str(path), locations=True)
    return handler.features


def extract_drainage(features, transformer, origin, tile_size: float) -> dict:
    if tile_size <= 0 or not math.isfinite(tile_size):
        raise ValueError("tile_size must be finite and positive")

    tiles = defaultdict(list)
    feature_ids = set()
    source_segments = 0
    tile_pieces = 0
    explicit_measure_features = 0
    by_kind = Counter()
    by_waterway = Counter()
    bounds = [float("inf"), float("inf"), float("-inf"), float("-inf")]

    for feature in features:
        tags = dict(feature.get("properties") or {})
        if isinstance(tags.get("tags"), dict):
            tags.update(tags["tags"])
        kind = drainage_kind(tags)
        if kind is None:
            continue
        geometry = feature.get("geometry") or {}
        if geometry.get("type") == "LineString":
            lines = [geometry.get("coordinates", [])]
        elif geometry.get("type") == "MultiLineString":
            lines = geometry.get("coordinates", [])
        else:
            continue

        source_id = str(feature.get("id") or tags.get("@id") or "")
        if not source_id:
            source_id = "drainage-" + hashlib.sha1(repr((lines, sorted(tags.items()))).encode()).hexdigest()[:20]
        if source_id in feature_ids:
            raise ValueError(f"Duplicate drainage source id: {source_id}")

        width_m, width_source = _finite_measure(tags)
        had_segment = False
        for line_index, line in enumerate(lines):
            if len(line) < 2:
                continue
            points = []
            for coordinate in line:
                if len(coordinate) < 2:
                    continue
                e, n = transformer.transform(float(coordinate[0]), float(coordinate[1]))
                point = (round(e - origin[0], 3), 0.0, round(origin[1] - n, 3))
                if not all(math.isfinite(value) for value in point):
                    raise ValueError(f"Non-finite drainage coordinate in {source_id}")
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
                        "kind": kind,
                        "waterway": _normal(tags.get("waterway")) or "unspecified",
                        "start": [round(start[0], 3), round(start[2], 3)],
                        "end": [round(end[0], 3), round(end[2], 3)],
                        "layer": str(tags.get("layer", "0")),
                    }
                    if width_m is not None:
                        record["width_m"] = width_m
                        record["width_source"] = width_source
                    for source_key in ("tunnel", "covered", "intermittent", "material"):
                        value = str(tags.get(source_key, "")).strip()
                        if value:
                            record[source_key] = value
                    tiles[(tx, tz)].append(record)
                    tile_pieces += 1
        if had_segment:
            feature_ids.add(source_id)
            by_kind[kind] += 1
            by_waterway[_normal(tags.get("waterway")) or "unspecified"] += 1
            explicit_measure_features += int(width_m is not None)

    for records in tiles.values():
        records.sort(key=lambda item: (item["source_way"], item["line"], item["segment"], item["start"]))
    if not feature_ids:
        bounds = []
    return {
        "tiles": dict(tiles),
        "stats": {
            "features": len(feature_ids),
            "source_segments": source_segments,
            "tile_pieces": tile_pieces,
            "tiles": len(tiles),
            "explicit_measure_features": explicit_measure_features,
            "by_kind": dict(sorted(by_kind.items())),
            "by_waterway": dict(sorted(by_waterway.items())),
        },
        "bounds": [round(value, 3) for value in bounds] if bounds else [],
    }


def write_dataset(input_path: Path, output_dir: Path, tile_size: float) -> dict:
    if input_path.suffix.lower() == ".pbf":
        features = _read_osm_drainage(input_path)
    else:
        features = json.loads(input_path.read_text(encoding="utf-8")).get("features", [])
    transformer = Transformer.from_crs(CRS_SOURCE, CRS_TARGET, always_xy=True)
    origin_e, origin_n = transformer.transform(ORIGIN_LON, ORIGIN_LAT)
    result = extract_drainage(features, transformer, (origin_e, origin_n), tile_size)

    staging = output_dir.with_name(output_dir.name + ".staging")
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    tile_entries = []
    for (tx, tz), records in sorted(result["tiles"].items()):
        filename = f"tile_{tx}_{tz}.json"
        (staging / filename).write_text(
            json.dumps({"tile": [tx, tz], "drainage": records}, separators=(",", ":")),
            encoding="utf-8",
        )
        tile_entries.append({"x": tx, "z": tz, "file": filename, "records": len(records)})

    manifest = {
        "format": 1,
        "purpose": "explicit OSM drainage evidence for Jamaica road engineering; never road or terrain authority",
        "source": "OpenStreetMap / Geofabrik Jamaica extract",
        "source_sha256": _hash_file(input_path),
        "attribution": "© OpenStreetMap contributors — https://www.openstreetmap.org/copyright (ODbL)",
        "crs": CRS_TARGET,
        "axis": "X=east, Z=south, metres",
        "tile_size": tile_size,
        "placement_rule": "mapped waterway=ditch/drain plus explicit culvert-tagged waterways only; generic streams are excluded",
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
    print("YARDMAN_DRAINAGE_BUILD PASS features=%d culverts=%d ditches=%d drains=%d source_segments=%d tile_pieces=%d tiles=%d" % (
        stats["features"], stats["by_kind"].get("culvert", 0), stats["by_kind"].get("ditch", 0),
        stats["by_kind"].get("drain", 0), stats["source_segments"], stats["tile_pieces"], stats["tiles"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
