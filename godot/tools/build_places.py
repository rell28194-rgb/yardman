#!/usr/bin/env python3
"""Compile named Jamaican places with parish-boundary authority into a compact runtime index."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import shutil
from collections import Counter, defaultdict
from pathlib import Path
from typing import Dict, Iterable, List, Mapping, MutableMapping, Sequence, Tuple

import osmium
from pyproj import Transformer

CRS_SOURCE = "EPSG:4326"
CRS_TARGET = "EPSG:3448"
ORIGIN_LAT = 17.9714
ORIGIN_LON = -76.7936
DEFAULT_TILE_SIZE = 4096.0
DEDUP_CELL_M = 250.0

PLACE_KINDS = {
    "city", "town", "village", "hamlet", "suburb", "neighbourhood",
    "quarter", "square", "locality",
}

PARISH_CAPITALS = {
    "Kingston": ("Kingston", 17.9714, -76.7936),
    "St. Andrew": ("Half Way Tree", 18.0120, -76.7970),
    "St. Catherine": ("Spanish Town", 17.9911, -76.9574),
    "Clarendon": ("May Pen", 17.9645, -77.2451),
    "Manchester": ("Mandeville", 18.0417, -77.5071),
    "St. Elizabeth": ("Black River", 18.0264, -77.8487),
    "Westmoreland": ("Savanna-la-Mar", 18.2190, -78.1332),
    "Hanover": ("Lucea", 18.4510, -78.1736),
    "St. James": ("Montego Bay", 18.4762, -77.8939),
    "Trelawny": ("Falmouth", 18.4936, -77.6559),
    "St. Ann": ("St. Ann's Bay", 18.4358, -77.2000),
    "St. Mary": ("Port Maria", 18.3685, -76.8895),
    "Portland": ("Port Antonio", 18.1762, -76.4509),
    "St. Thomas": ("Morant Bay", 17.8815, -76.4093),
}


def _clean(value: object) -> str:
    return str(value or "").strip()


def classify_place(tags: Mapping[str, str]) -> str:
    place = _clean(tags.get("place")).lower()
    if place in PLACE_KINDS:
        return place
    if (_clean(tags.get("highway")).lower() == "pedestrian"
            and _clean(tags.get("area")).lower() in {"yes", "1", "true"}
            and _clean(tags.get("name"))):
        return "square"
    return ""


def is_capital(tags: Mapping[str, str]) -> bool:
    value = _clean(tags.get("capital")).lower()
    return bool(value and value not in {"no", "0", "false"})


def _nearest_parish(x: float, z: float, anchors: Mapping[str, Tuple[float, float]]) -> str:
    """Diagnostic fallback only. Runtime parish truth comes from admin polygons."""
    best_name = ""
    best_distance = math.inf
    for name, point in anchors.items():
        distance = (x - point[0]) ** 2 + (z - point[1]) ** 2
        if distance < best_distance:
            best_distance = distance
            best_name = name
    return best_name


def _normal_name(value: str) -> str:
    return " ".join(value.casefold().replace("’", "'").split())


def _parish_token(value: str) -> str:
    token = _normal_name(value).replace("’", "'")
    token = token.replace("saint ", "st ").replace("st. ", "st ")
    if token.endswith(" parish"):
        token = token[:-7].strip()
    return token


_PARISH_BY_TOKEN = {_parish_token(name): name for name in PARISH_CAPITALS}


def canonical_parish_name(tags_or_name: object) -> str:
    """Resolve OSM parish naming variants to one of Yardman's 14 canonical names."""
    if isinstance(tags_or_name, Mapping):
        tags = tags_or_name
        candidates = [tags.get("name"), tags.get("official_name"), tags.get("short_name"), tags.get("alt_name")]
    else:
        candidates = [tags_or_name]
    for candidate in candidates:
        token = _parish_token(_clean(candidate))
        if token in _PARISH_BY_TOKEN:
            return _PARISH_BY_TOKEN[token]
    return ""


def _point_on_segment(px: float, py: float, ax: float, ay: float,
                      bx: float, by: float, tolerance: float = 1.0e-10) -> bool:
    cross = (px - ax) * (by - ay) - (py - ay) * (bx - ax)
    if abs(cross) > tolerance:
        return False
    dot = (px - ax) * (px - bx) + (py - ay) * (py - by)
    return dot <= tolerance


def point_in_ring(lon: float, lat: float, ring: Sequence[Sequence[float]]) -> bool:
    """Ray-cast in WGS84 lon/lat. Boundary points count as contained."""
    if len(ring) < 3:
        return False
    inside = False
    j = len(ring) - 1
    for i, current in enumerate(ring):
        previous = ring[j]
        if len(current) < 2 or len(previous) < 2:
            j = i
            continue
        xi, yi = float(current[0]), float(current[1])
        xj, yj = float(previous[0]), float(previous[1])
        if _point_on_segment(lon, lat, xi, yi, xj, yj):
            return True
        crosses = (yi > lat) != (yj > lat)
        if crosses:
            x_at_lat = (xj - xi) * (lat - yi) / (yj - yi) + xi
            if lon < x_at_lat:
                inside = not inside
        j = i
    return inside


def _polygon_contains(lon: float, lat: float, polygon: Sequence[Sequence[Sequence[float]]]) -> bool:
    if not polygon or not point_in_ring(lon, lat, polygon[0]):
        return False
    for hole in polygon[1:]:
        if point_in_ring(lon, lat, hole):
            return False
    return True


def geometry_contains(geometry: Mapping[str, object], lon: float, lat: float) -> bool:
    kind = _clean(geometry.get("type"))
    coordinates = geometry.get("coordinates", [])
    if not isinstance(coordinates, Sequence):
        return False
    if kind == "Polygon":
        return _polygon_contains(lon, lat, coordinates)
    if kind == "MultiPolygon":
        return any(_polygon_contains(lon, lat, polygon) for polygon in coordinates)
    return False


def parish_from_boundaries(lon: float, lat: float,
                           boundaries: Mapping[str, Sequence[Mapping[str, object]]]) -> str:
    matches = [
        parish for parish, geometries in boundaries.items()
        if any(geometry_contains(geometry, lon, lat) for geometry in geometries)
    ]
    # Administrative parish interiors should not overlap. Refuse to invent a
    # winner if malformed source geometry produces ambiguity.
    return matches[0] if len(matches) == 1 else ""


def _load_parish_boundaries(input_path: Path) -> Tuple[Dict[str, List[dict]], dict]:
    factory = osmium.geom.GeoJSONFactory()
    boundaries: Dict[str, List[dict]] = defaultdict(list)
    source_areas = 0
    rejected_admin6 = 0
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
            rejected_admin6 += 1
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

    missing = sorted(set(PARISH_CAPITALS) - set(boundaries))
    stats = {
        "source_admin_level_6_areas": source_areas,
        "canonical_parishes": len(boundaries),
        "geometry_parts": sum(len(parts) for parts in boundaries.values()),
        "rejected_admin_level_6_areas": rejected_admin6,
        "geometry_errors": geometry_errors,
        "missing_parishes": missing,
    }
    if missing:
        raise RuntimeError("missing authoritative parish boundary geometry: " + ", ".join(missing))
    return dict(boundaries), stats


def _record(name: str, kind: str, lon: float, lat: float, source: str,
            transformer: Transformer, origin: Tuple[float, float],
            parish_anchors: Mapping[str, Tuple[float, float]],
            parish_boundaries: Mapping[str, Sequence[Mapping[str, object]]],
            tags: Mapping[str, str]) -> dict:
    easting, northing = transformer.transform(lon, lat)
    x = float(easting - origin[0])
    z = float(origin[1] - northing)
    population = _clean(tags.get("population"))
    parish = parish_from_boundaries(lon, lat, parish_boundaries)
    assignment = "admin_level_6_polygon"
    if not parish:
        parish = _nearest_parish(x, z, parish_anchors)
        assignment = "nearest_capital_fallback"
    return {
        "name": name,
        "kind": kind,
        "x": round(x, 3),
        "z": round(z, 3),
        "parish": parish,
        "parish_assignment": assignment,
        "capital": is_capital(tags),
        "population": population,
        "source": source,
    }


class _PlaceHandler(osmium.SimpleHandler):
    def __init__(self, transformer: Transformer, origin: Tuple[float, float],
                 parish_anchors: Mapping[str, Tuple[float, float]],
                 parish_boundaries: Mapping[str, Sequence[Mapping[str, object]]]):
        super().__init__()
        self.transformer = transformer
        self.origin = origin
        self.parish_anchors = parish_anchors
        self.parish_boundaries = parish_boundaries
        self.records: List[dict] = []

    def node(self, node) -> None:
        tags = {tag.k: tag.v for tag in node.tags}
        name = _clean(tags.get("name"))
        kind = classify_place(tags)
        if not name or not kind:
            return
        try:
            lon, lat = float(node.location.lon), float(node.location.lat)
        except Exception:
            return
        self.records.append(_record(
            name, kind, lon, lat, f"node/{node.id}", self.transformer,
            self.origin, self.parish_anchors, self.parish_boundaries, tags))

    def way(self, way) -> None:
        tags = {tag.k: tag.v for tag in way.tags}
        name = _clean(tags.get("name"))
        kind = classify_place(tags)
        if not name or kind != "square":
            return
        points: List[Tuple[float, float]] = []
        for node in way.nodes:
            try:
                points.append((float(node.lon), float(node.lat)))
            except Exception:
                continue
        if len(points) < 2:
            return
        lon = sum(point[0] for point in points) / len(points)
        lat = sum(point[1] for point in points) / len(points)
        self.records.append(_record(
            name, kind, lon, lat, f"way/{way.id}", self.transformer,
            self.origin, self.parish_anchors, self.parish_boundaries, tags))


def _dedupe_key(record: Mapping[str, object]) -> Tuple[object, ...]:
    name = _normal_name(str(record.get("name", "")))
    kind = str(record.get("kind", ""))
    x, z = record.get("x"), record.get("z")
    if isinstance(x, (int, float)) and isinstance(z, (int, float)) and math.isfinite(float(x)) and math.isfinite(float(z)):
        # Repeated OSM representations of one place collapse locally while
        # legitimate same-name settlements elsewhere on the island survive.
        return (name, kind, round(float(x) / DEDUP_CELL_M), round(float(z) / DEDUP_CELL_M))
    return (name, kind)


def _dedupe(records: Iterable[dict]) -> List[dict]:
    best: Dict[Tuple[object, ...], dict] = {}
    priority = {"square": 9, "neighbourhood": 8, "quarter": 7, "suburb": 6,
                "city": 5, "town": 4, "village": 3, "hamlet": 2, "locality": 1,
                "parish_capital": 10}
    for record in records:
        key = _dedupe_key(record)
        previous = best.get(key)
        if previous is None or bool(record.get("capital")) > bool(previous.get("capital")):
            best[key] = record
    # Keep same-name records of different semantic types; the runtime can compose
    # a square/neighbourhood with its parent settlement.
    return sorted(best.values(), key=lambda r: (_normal_name(r["name"]), -priority.get(r["kind"], 0), r["source"]))


def _ensure_parish_capitals(records: List[dict], transformer: Transformer,
                            origin: Tuple[float, float], parish_anchors: Mapping[str, Tuple[float, float]],
                            parish_boundaries: Mapping[str, Sequence[Mapping[str, object]]]) -> None:
    by_name: MutableMapping[str, List[dict]] = defaultdict(list)
    for record in records:
        by_name[_normal_name(record["name"])].append(record)
    for parish, (name, lat, lon) in PARISH_CAPITALS.items():
        candidates = by_name.get(_normal_name(name), [])
        if candidates:
            candidate = min(candidates, key=lambda r: (r["x"] - parish_anchors[parish][0]) ** 2 + (r["z"] - parish_anchors[parish][1]) ** 2)
            candidate["capital"] = True
            candidate["parish"] = parish
            candidate["parish_assignment"] = "canonical_capital"
            candidate["capital_level"] = "national" if parish == "Kingston" else "parish"
            continue
        record = _record(name, "parish_capital", lon, lat, f"fallback/{parish}", transformer, origin,
                         parish_anchors, parish_boundaries, {"capital": "yes"})
        record["parish"] = parish
        record["parish_assignment"] = "canonical_capital_fallback"
        record["capital_level"] = "national" if parish == "Kingston" else "parish"
        records.append(record)


def compile_places(input_path: Path, output_dir: Path, tile_size: float = DEFAULT_TILE_SIZE) -> dict:
    if tile_size <= 0.0 or not math.isfinite(tile_size):
        raise ValueError("tile size must be finite and positive")
    if input_path.suffix.lower() != ".pbf":
        raise ValueError("place compilation currently requires the Jamaica OSM PBF")

    transformer = Transformer.from_crs(CRS_SOURCE, CRS_TARGET, always_xy=True)
    origin = transformer.transform(ORIGIN_LON, ORIGIN_LAT)
    parish_anchors: Dict[str, Tuple[float, float]] = {}
    for parish, (_, lat, lon) in PARISH_CAPITALS.items():
        easting, northing = transformer.transform(lon, lat)
        parish_anchors[parish] = (float(easting - origin[0]), float(origin[1] - northing))

    parish_boundaries, boundary_stats = _load_parish_boundaries(input_path)
    handler = _PlaceHandler(transformer, origin, parish_anchors, parish_boundaries)
    handler.apply_file(str(input_path), locations=True)
    raw_count = len(handler.records)
    records = _dedupe(handler.records)
    _ensure_parish_capitals(records, transformer, origin, parish_anchors, parish_boundaries)
    records = _dedupe(records)

    tiles: Dict[str, List[dict]] = defaultdict(list)
    kinds = Counter()
    parish_counts = Counter()
    assignment_counts = Counter()
    for record in records:
        tx = math.floor(float(record["x"]) / tile_size)
        tz = math.floor(float(record["z"]) / tile_size)
        tiles[f"{tx}:{tz}"].append(record)
        kinds[record["kind"]] += 1
        parish_counts[record["parish"]] += 1
        assignment_counts[record.get("parish_assignment", "unknown")] += 1
    for values in tiles.values():
        values.sort(key=lambda r: (_normal_name(r["name"]), r["kind"]))

    manifest = {
        "format": 2,
        "source": "OpenStreetMap / Geofabrik Jamaica extract",
        "source_sha256": hashlib.sha256(input_path.read_bytes()).hexdigest(),
        "attribution": "© OpenStreetMap contributors — https://www.openstreetmap.org/copyright (ODbL)",
        "crs": CRS_TARGET,
        "origin": {"lat": ORIGIN_LAT, "lon": ORIGIN_LON, "easting": origin[0], "northing": origin[1]},
        "axis": "X=east, Z=south, metres",
        "tile_size": tile_size,
        "parish_assignment_authority": "OSM boundary=administrative admin_level=6 polygon containment; nearest-capital only explicit diagnostic fallback",
        "parish_boundary_stats": boundary_stats,
        "parish_capitals": {parish: {"name": values[0], "x": parish_anchors[parish][0], "z": parish_anchors[parish][1]}
                            for parish, values in PARISH_CAPITALS.items()},
        "tiles": dict(sorted(tiles.items())),
        "stats": {
            "raw_places": raw_count,
            "places": len(records),
            "tiles": len(tiles),
            "by_kind": dict(sorted(kinds.items())),
            "by_parish": dict(sorted(parish_counts.items())),
            "parish_assignment": dict(sorted(assignment_counts.items())),
        },
    }

    staging = output_dir.with_name(output_dir.name + ".staging")
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    (staging / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True), encoding="utf-8")
    if output_dir.exists():
        shutil.rmtree(output_dir)
    staging.replace(output_dir)
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input_pbf", type=Path)
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("--tile-size", type=float, default=DEFAULT_TILE_SIZE)
    args = parser.parse_args()
    manifest = compile_places(args.input_pbf, args.output_dir, args.tile_size)
    print("YARDMAN_PLACES_BUILD PASS", json.dumps(manifest["stats"], sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
