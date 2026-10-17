#!/usr/bin/env python3
"""Compile source-backed Jamaica waterways into the Yardman world grid.

This stage does not invent channels. It preserves mapped OSM waterway geometry,
projects it into EPSG:3448 / Yardman local metres, splits it exactly at runtime
tile boundaries, and samples the existing DEM at every emitted endpoint. The
result is factual centerline/elevation input for later channel carving, banks,
floodplain treatment, culverts and bridge-crossing validation.

Crossing semantics are retained deliberately. A mapped waterway can be covered,
underground or explicitly tagged as a culvert/tunnel. Those records must never
be treated as ordinary open-channel cuts merely because their plan geometry
intersects a road.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import shutil
from collections import Counter, defaultdict
from pathlib import Path

WATERWAY_CLASSES = {"river", "stream", "canal", "drain", "ditch"}
DEFAULT_WIDTH_M = {
    "river": 18.0,
    "stream": 5.0,
    "canal": 8.0,
    "drain": 2.5,
    "ditch": 1.5,
}
TRUE_TAGS = {"yes", "true", "1"}
FALSE_TAGS = {"", "no", "false", "0"}


def parse_bool_tag(raw) -> bool:
    return str(raw or "").strip().lower() in TRUE_TAGS


def parse_layer(raw) -> int:
    try:
        value = int(str(raw if raw is not None else "0").strip())
    except ValueError:
        return 0
    return max(-20, min(20, value))


def parse_width_m(raw: str | None, waterway: str) -> float:
    """Preserve explicit width when usable, otherwise use a class fallback.

    The fallback is presentation/channel-seeding metadata only; it never changes
    source centerline position and is tagged as inferred in the output record.
    """
    if raw:
        match = re.search(r"[-+]?\d+(?:\.\d+)?", str(raw))
        if match:
            value = float(match.group(0))
            if math.isfinite(value) and value > 0.0:
                return max(0.5, min(200.0, value))
    return DEFAULT_WIDTH_M.get(waterway, 3.0)


def waterway_structure(tags) -> dict:
    tunnel = str(tags.get("tunnel", "") or "").strip().lower()
    culvert = tunnel == "culvert" or parse_bool_tag(tags.get("culvert"))
    covered = parse_bool_tag(tags.get("covered")) or str(tags.get("location", "")).strip().lower() == "underground"
    underground = culvert or covered or (tunnel not in FALSE_TAGS)
    return {
        "tunnel": tunnel,
        "layer": parse_layer(tags.get("layer")),
        "covered": covered,
        "culvert": culvert,
        "underground": underground,
        "location": str(tags.get("location", "") or "").strip().lower(),
    }


def _interpolate(a: tuple[float, float], b: tuple[float, float], t: float) -> tuple[float, float]:
    return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)


def split_segment_by_tile(
    a: tuple[float, float], b: tuple[float, float], tile_size: float
) -> list[tuple[tuple[int, int], tuple[float, float], tuple[float, float]]]:
    """Split one X/Z segment at every national tile seam.

    Tile selection uses the fragment midpoint so negative coordinates and exact
    seam endpoints remain deterministic. Adjacent fragments share bit-identical
    interpolated X/Z seam coordinates.
    """
    if tile_size <= 0.0 or not math.isfinite(tile_size):
        raise ValueError("tile_size must be finite and positive")
    dx, dz = b[0] - a[0], b[1] - a[1]
    if abs(dx) < 1e-12 and abs(dz) < 1e-12:
        return []
    cuts = [0.0, 1.0]

    def add_axis_cuts(start: float, delta: float) -> None:
        if abs(delta) < 1e-12:
            return
        lo, hi = sorted((start, start + delta))
        first = math.floor(lo / tile_size) + 1
        last = math.floor(hi / tile_size)
        for index in range(first, last + 1):
            boundary = index * tile_size
            t = (boundary - start) / delta
            if 1e-12 < t < 1.0 - 1e-12:
                cuts.append(t)

    add_axis_cuts(a[0], dx)
    add_axis_cuts(a[1], dz)
    cuts = sorted(set(round(value, 15) for value in cuts))
    result = []
    for t0, t1 in zip(cuts, cuts[1:]):
        if t1 - t0 <= 1e-12:
            continue
        pa, pb = _interpolate(a, b, t0), _interpolate(a, b, t1)
        mid = _interpolate(a, b, (t0 + t1) * 0.5)
        tile = (math.floor(mid[0] / tile_size), math.floor(mid[1] / tile_size))
        result.append((tile, pa, pb))
    return result


def compile_hydrology(osm_pbf: Path, terrain_root: Path, output_root: Path) -> dict:
    try:
        import osmium
        from pyproj import Transformer
    except ImportError as exc:  # pragma: no cover - exercised in build workflow
        raise RuntimeError("build_hydrology requires osmium and pyproj") from exc

    from build_terrain import TerrainSampler

    terrain_manifest = json.loads((terrain_root / "manifest.json").read_text(encoding="utf-8"))
    tile_size = float(terrain_manifest["tile_size"])
    origin = terrain_manifest["origin"]
    e0, n0 = float(origin["easting"]), float(origin["northing"])
    project = Transformer.from_crs(4326, 3448, always_xy=True)
    sampler = TerrainSampler(terrain_root)

    records_by_tile: dict[tuple[int, int], list[list]] = defaultdict(list)
    stats: Counter = Counter()

    class Handler(osmium.SimpleHandler):
        def way(self, way) -> None:
            waterway = str(way.tags.get("waterway", ""))
            if waterway not in WATERWAY_CLASSES:
                return
            source_points: list[tuple[float, float, int]] = []
            for node in way.nodes:
                try:
                    if not node.location.valid():
                        continue
                    easting, northing = project.transform(node.location.lon, node.location.lat)
                except Exception:
                    continue
                source_points.append((float(easting) - e0, n0 - float(northing), int(node.ref)))
            if len(source_points) < 2:
                stats["rejected_short_ways"] += 1
                return

            name = str(way.tags.get("name", ""))
            raw_width = way.tags.get("width")
            width_m = parse_width_m(raw_width, waterway)
            width_source = "source" if raw_width and re.search(r"[-+]?\d+(?:\.\d+)?", str(raw_width)) else "class_fallback"
            intermittent = parse_bool_tag(way.tags.get("intermittent"))
            tidal = parse_bool_tag(way.tags.get("tidal"))
            structure = waterway_structure(way.tags)
            source_id = f"w{int(way.id)}"
            emitted = 0
            for source_segment_index, (source_a, source_b) in enumerate(zip(source_points, source_points[1:])):
                p0, p1 = source_a[:2], source_b[:2]
                for (tx, tz), a, b in split_segment_by_tile(p0, p1, tile_size):
                    try:
                        ay = float(sampler(a[0], a[1]))
                        by = float(sampler(b[0], b[1]))
                    except ValueError:
                        stats["segments_outside_dem"] += 1
                        continue
                    if not all(math.isfinite(value) for value in (ay, by)):
                        stats["segments_nonfinite_dem"] += 1
                        continue
                    records_by_tile[(tx, tz)].append([
                        round(a[0], 6), round(ay, 6), round(a[1], 6),
                        round(b[0], 6), round(by, 6), round(b[1], 6),
                        source_id, waterway, name, round(width_m, 3), width_source,
                        intermittent, tidal, source_segment_index,
                        int(source_a[2]), int(source_b[2]),
                        structure["tunnel"], structure["layer"], structure["covered"],
                        structure["culvert"], structure["underground"], structure["location"],
                    ])
                    emitted += 1
            if emitted:
                stats["source_ways"] += 1
                stats[f"class_{waterway}"] += 1
                stats["segments"] += emitted
                if name:
                    stats["named_ways"] += 1
                if intermittent:
                    stats["intermittent_ways"] += 1
                if tidal:
                    stats["tidal_ways"] += 1
                if structure["culvert"]:
                    stats["culvert_ways"] += 1
                elif structure["underground"]:
                    stats["other_underground_ways"] += 1

    Handler().apply_file(str(osm_pbf), locations=True)

    staging = output_root.with_name(output_root.name + ".staging")
    if staging.exists():
        shutil.rmtree(staging)
    (staging / "tiles").mkdir(parents=True)
    tile_entries = []
    for (tx, tz), records in sorted(records_by_tile.items()):
        records.sort(key=lambda item: (item[6], item[13], item[0], item[2], item[3], item[5]))
        relative = f"tiles/tile_{tx}_{tz}.json"
        (staging / relative).write_text(
            json.dumps({"tile": [tx, tz], "segments": records}, separators=(",", ":")),
            encoding="utf-8",
        )
        tile_entries.append({"x": tx, "z": tz, "file": relative, "segments": len(records)})

    manifest = {
        "format": 2,
        "crs": "EPSG:3448",
        "axis": "X east, Y elevation, Z south; real metres",
        "origin": origin,
        "tile_size": tile_size,
        "source": "OpenStreetMap waterway ways from Jamaica Geofabrik extract",
        "terrain_source": terrain_manifest.get("source", "Yardman terrain DEM"),
        "geometry_status": "source centerlines registered to DEM; terrain channel carving is a later stage",
        "record_format": [
            "ax", "ay", "az", "bx", "by", "bz", "source_way", "waterway",
            "name", "width_m", "width_source", "intermittent", "tidal",
            "source_segment_index", "source_node_a", "source_node_b", "tunnel",
            "layer", "covered", "culvert", "underground", "location",
        ],
        "stats": dict(sorted(stats.items())),
        "tiles": tile_entries,
    }
    (staging / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True), encoding="utf-8")
    if output_root.exists():
        shutil.rmtree(output_root)
    staging.replace(output_root)
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("osm_pbf", type=Path)
    parser.add_argument("terrain_root", type=Path)
    parser.add_argument("output_root", type=Path)
    args = parser.parse_args()
    manifest = compile_hydrology(args.osm_pbf, args.terrain_root, args.output_root)
    print("YARDMAN_HYDROLOGY_COMPILE_PASS", json.dumps(manifest["stats"], sort_keys=True),
          "tiles=", len(manifest["tiles"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
