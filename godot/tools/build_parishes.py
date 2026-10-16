#!/usr/bin/env python3
"""Compile Jamaica parish admin boundaries into Yardman's metre coordinate frame."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import shutil
from collections import defaultdict
from pathlib import Path
from typing import Dict, Iterable, List, Mapping, Sequence, Tuple

import osmium
from pyproj import Transformer

CRS_SOURCE = "EPSG:4326"
CRS_TARGET = "EPSG:3448"
ORIGIN_LAT = 17.9714
ORIGIN_LON = -76.7936

PARISHES = (
    "Kingston", "St. Andrew", "St. Catherine", "Clarendon", "Manchester",
    "St. Elizabeth", "Westmoreland", "Hanover", "St. James", "Trelawny",
    "St. Ann", "St. Mary", "Portland", "St. Thomas",
)


def _clean(value: object) -> str:
    return str(value or "").strip()


def _normal_name(value: str) -> str:
    return " ".join(value.casefold().replace("’", "'").split())


def _parish_token(value: str) -> str:
    token = _normal_name(value).replace("saint ", "st ").replace("st. ", "st ")
    if token.endswith(" parish"):
        token = token[:-7].strip()
    return token


_PARISH_BY_TOKEN = {_parish_token(name): name for name in PARISHES}


def canonical_parish_name(tags_or_name: object) -> str:
    if isinstance(tags_or_name, Mapping):
        candidates = [
            tags_or_name.get("name"), tags_or_name.get("official_name"),
            tags_or_name.get("short_name"), tags_or_name.get("alt_name"),
        ]
    else:
        candidates = [tags_or_name]
    for candidate in candidates:
        parish = _PARISH_BY_TOKEN.get(_parish_token(_clean(candidate)), "")
        if parish:
            return parish
    return ""


def _load_boundaries(input_path: Path) -> Tuple[Dict[str, List[dict]], dict]:
    factory = osmium.geom.GeoJSONFactory()
    boundaries: Dict[str, List[dict]] = defaultdict(list)
    source_areas = 0
    rejected = 0
    geometry_errors = 0
    for obj in osmium.FileProcessor(str(input_path)).with_areas():
        if not obj.is_area():
            continue
        tags = {tag.k: tag.v for tag in obj.tags}
        if _clean(tags.get("boundary")).lower() != "administrative" or _clean(tags.get("admin_level")) != "6":
            continue
        source_areas += 1
        parish = canonical_parish_name(tags)
        if not parish:
            rejected += 1
            continue
        try:
            geometry = json.loads(factory.create_multipolygon(obj))
        except Exception:
            geometry_errors += 1
            continue
        if geometry and geometry.get("type") in {"Polygon", "MultiPolygon"}:
            boundaries[parish].append(geometry)
        else:
            geometry_errors += 1
    missing = sorted(set(PARISHES) - set(boundaries))
    if missing:
        raise RuntimeError("missing authoritative parish boundary geometry: " + ", ".join(missing))
    return dict(boundaries), {
        "source_admin_level_6_areas": source_areas,
        "canonical_parishes": len(boundaries),
        "geometry_parts": sum(len(parts) for parts in boundaries.values()),
        "rejected_admin_level_6_areas": rejected,
        "geometry_errors": geometry_errors,
        "missing_parishes": missing,
    }


def _project_ring(ring: Sequence[Sequence[float]], transformer: Transformer,
                  origin: Tuple[float, float]) -> List[List[float]]:
    points: List[List[float]] = []
    previous: Tuple[float, float] | None = None
    for raw in ring:
        if len(raw) < 2:
            continue
        easting, northing = transformer.transform(float(raw[0]), float(raw[1]))
        point = (round(float(easting - origin[0]), 2), round(float(origin[1] - northing), 2))
        if point == previous:
            continue
        points.append([point[0], point[1]])
        previous = point
    if len(points) >= 3 and points[0] != points[-1]:
        points.append(points[0].copy())
    return points


def project_boundaries(boundaries: Mapping[str, Sequence[Mapping[str, object]]],
                       transformer: Transformer, origin: Tuple[float, float]) -> Dict[str, List[dict]]:
    result: Dict[str, List[dict]] = {}
    for parish, geometries in sorted(boundaries.items()):
        polygons: List[dict] = []
        for geometry in geometries:
            kind = _clean(geometry.get("type"))
            coords = geometry.get("coordinates", [])
            raw_polygons: Iterable = [coords] if kind == "Polygon" else coords if kind == "MultiPolygon" else []
            for raw_polygon in raw_polygons:
                if not isinstance(raw_polygon, Sequence) or not raw_polygon:
                    continue
                rings = [_project_ring(ring, transformer, origin) for ring in raw_polygon]
                rings = [ring for ring in rings if len(ring) >= 4]
                if not rings:
                    continue
                outer = rings[0]
                xs = [float(point[0]) for point in outer]
                zs = [float(point[1]) for point in outer]
                polygons.append({
                    "bounds": [round(min(xs), 2), round(min(zs), 2), round(max(xs), 2), round(max(zs), 2)],
                    "rings": rings,
                })
        if polygons:
            result[parish] = polygons
    missing = sorted(set(PARISHES) - set(result))
    if missing:
        raise RuntimeError("projected parish boundary geometry missing: " + ", ".join(missing))
    return result


def compile_parishes(input_path: Path, output_dir: Path) -> dict:
    if input_path.suffix.lower() != ".pbf":
        raise ValueError("parish compilation requires the Jamaica OSM PBF")
    transformer = Transformer.from_crs(CRS_SOURCE, CRS_TARGET, always_xy=True)
    origin = transformer.transform(ORIGIN_LON, ORIGIN_LAT)
    boundaries, source_stats = _load_boundaries(input_path)
    projected = project_boundaries(boundaries, transformer, origin)
    vertices = sum(
        len(ring)
        for polygons in projected.values()
        for polygon in polygons
        for ring in polygon["rings"]
    )
    manifest = {
        "format": 1,
        "source": "OpenStreetMap / Geofabrik Jamaica extract",
        "source_sha256": hashlib.sha256(input_path.read_bytes()).hexdigest(),
        "attribution": "© OpenStreetMap contributors — https://www.openstreetmap.org/copyright (ODbL)",
        "crs": CRS_TARGET,
        "origin": {"lat": ORIGIN_LAT, "lon": ORIGIN_LON, "easting": origin[0], "northing": origin[1]},
        "axis": "X=east, Z=south, metres",
        "authority": "OSM boundary=administrative admin_level=6 polygon containment",
        "parishes": projected,
        "stats": {
            **source_stats,
            "runtime_polygons": sum(len(polygons) for polygons in projected.values()),
            "runtime_vertices": vertices,
        },
    }
    staging = output_dir.with_name(output_dir.name + ".staging")
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    (staging / "manifest.json").write_text(json.dumps(manifest, separators=(",", ":")), encoding="utf-8")
    if output_dir.exists():
        shutil.rmtree(output_dir)
    staging.replace(output_dir)
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input_pbf", type=Path)
    parser.add_argument("output_dir", type=Path)
    args = parser.parse_args()
    manifest = compile_parishes(args.input_pbf, args.output_dir)
    print("YARDMAN_PARISH_BUILD PASS", json.dumps(manifest["stats"], sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
