#!/usr/bin/env python3
"""Compile shared-edge, metre-height terrain from public Copernicus COGs."""
from __future__ import annotations
import argparse
import concurrent.futures
import hashlib
import json
import math
import shutil
import urllib.request
from pathlib import Path

import numpy as np
import rasterio
from rasterio.merge import merge
from pyproj import Transformer

BASE = "https://copernicus-dem-30m.s3.amazonaws.com/"
NOTICE = ("produced using Copernicus WorldDEM-30 © DLR e.V. 2010-2014 and "
          "© Airbus Defence and Space GmbH 2014-2018 provided under COPERNICUS "
          "by the European Union and ESA; all rights reserved")


def acquire(source_dir: Path) -> list[dict]:
    source_dir.mkdir(parents=True, exist_ok=True)
    listing = urllib.request.urlopen(BASE + "tileList.txt", timeout=60).read().decode()
    names = sorted(name.strip().strip("/") for name in listing.splitlines()
                   if any(f"_N{lat}_00_W{lon:03}_00_" in name
                          for lat in (17, 18) for lon in (77, 78, 79)))
    if len(names) != 5:
        raise ValueError("Public DEM tile coverage changed; inspect the source index")
    def fetch(name):
        path = source_dir / (name + ".tif")
        url = BASE + name + "/" + name + ".tif"
        if not path.exists():
            temporary = path.with_suffix(".download")
            urllib.request.urlretrieve(url, temporary)
            temporary.replace(path)
        return {"file": path.name, "url": url, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        records = list(pool.map(fetch, names))
    (source_dir / "sources.json").write_text(json.dumps(records, indent=2))
    return records


def compile_terrain(source_dir: Path, roads_manifest: Path, output: Path, resolution=65) -> dict:
    if resolution < 3 or (resolution - 1) & (resolution - 2):
        raise ValueError("Terrain resolution must be one plus a power of two")
    roads = json.loads(roads_manifest.read_text())
    size = float(roads["tile_size"])
    spacing = size / (resolution - 1)
    bounds = roads["bounds"]
    tx0, tz0 = math.floor(bounds[0] / size) - 1, math.floor(bounds[1] / size) - 1
    tx1, tz1 = math.floor(bounds[2] / size) + 1, math.floor(bounds[3] / size) + 1
    # One national sample grid guarantees byte-identical shared tile edges.
    xs = np.arange((tx1 - tx0 + 1) * (resolution - 1) + 1, dtype=np.float64) * spacing + tx0 * size
    zs = np.arange((tz1 - tz0 + 1) * (resolution - 1) + 1, dtype=np.float64) * spacing + tz0 * size
    records = json.loads((source_dir / "sources.json").read_text())
    datasets = [rasterio.open(source_dir / record["file"]) for record in records]
    try:
        if any(str(dataset.crs) != "EPSG:4326" for dataset in datasets):
            raise ValueError("Unexpected DEM source CRS")
        mosaic, transform = merge(datasets, nodata=0.0)
    finally:
        for dataset in datasets:
            dataset.close()
    source = mosaic[0]
    inverse = Transformer.from_crs(3448, 4326, always_xy=True)
    height = np.zeros((len(zs), len(xs)), dtype="<f4")
    e0, n0 = float(roads["origin"]["easting"]), float(roads["origin"]["northing"])
    for row in range(0, len(zs), 64):
        xx, zz = np.meshgrid(xs, zs[row:row + 64])
        lon, lat = inverse.transform(xx + e0, n0 - zz)
        col = (lon - transform.c) / transform.a - 0.5
        line = (lat - transform.f) / transform.e - 0.5
        ix, iz = np.floor(col).astype(int), np.floor(line).astype(int)
        valid = (ix >= 0) & (iz >= 0) & (ix < source.shape[1] - 1) & (iz < source.shape[0] - 1)
        ix = np.clip(ix, 0, source.shape[1] - 2)
        iz = np.clip(iz, 0, source.shape[0] - 2)
        fx, fz = col - ix, line - iz
        values = ((source[iz, ix] * (1 - fx) + source[iz, ix + 1] * fx) * (1 - fz)
                  + (source[iz + 1, ix] * (1 - fx) + source[iz + 1, ix + 1] * fx) * fz)
        values[~valid] = 0.0
        if not np.isfinite(values).all():
            raise ValueError("Non-finite DEM height")
        height[row:row + 64] = values
    staging = output.with_name(output.name + ".staging")
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    entries = []
    stride = resolution - 1
    for tz in range(tz0, tz1 + 1):
        for tx in range(tx0, tx1 + 1):
            tile = height[(tz - tz0) * stride:(tz - tz0 + 1) * stride + 1,
                          (tx - tx0) * stride:(tx - tx0 + 1) * stride + 1]
            path = f"height_{tx}_{tz}.bin"
            (staging / path).write_bytes(tile.astype("<f4").tobytes())
            entries.append({"x": tx, "z": tz, "file": path,
                            "min": float(tile.min()), "max": float(tile.max())})
    overview = height[::8, ::8]
    (staging / "overview.bin").write_bytes(overview.astype("<f4").tobytes())
    manifest = {"format": 1, "crs": "EPSG:3448", "vertical_datum": "EGM2008",
                "axis": "X east, Y elevation, Z south; real metres",
                "source": "Copernicus GLO-30 Public (2021 AWS release), DSM",
                "source_resolution_m": 30, "attribution": NOTICE, "sources": records,
                "origin": roads["origin"], "tile_size": size, "resolution": resolution,
                "sample_spacing_m": spacing, "height_encoding": "little-endian float32 metres, row-major Z then X",
                "bounds": [float(xs[0]), float(zs[0]), float(xs[-1]), float(zs[-1])],
                "min_height": float(height.min()), "max_height": float(height.max()),
                "tiles": entries, "overview": {"file": "overview.bin",
                    "origin_x": float(xs[0]), "origin_z": float(zs[0]),
                    "width": int(overview.shape[1]), "depth": int(overview.shape[0]), "spacing": spacing * 8}}
    (staging / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True))
    if output.exists():
        shutil.rmtree(output)
    staging.replace(output)
    validate_seams(output, manifest)
    if manifest["max_height"] < 2000 or manifest["max_height"] > 2400:
        raise ValueError("Jamaica mountain-height QA failed")
    return manifest


def validate_seams(root: Path, manifest: dict) -> None:
    res = manifest["resolution"]
    tiles = {(tile["x"], tile["z"]): np.fromfile(root / tile["file"], dtype="<f4").reshape(res, res)
             for tile in manifest["tiles"]}
    for (x, z), tile in tiles.items():
        if (x + 1, z) in tiles and not np.array_equal(tile[:, -1], tiles[x + 1, z][:, 0]):
            raise ValueError(f"East terrain seam differs at {(x, z)}")
        if (x, z + 1) in tiles and not np.array_equal(tile[-1, :], tiles[x, z + 1][0, :]):
            raise ValueError(f"South terrain seam differs at {(x, z)}")


class TerrainSampler:
    """Use the exact same piecewise triangles as runtime render/collision."""
    def __init__(self, root: Path):
        self.manifest = json.loads((root / "manifest.json").read_text())
        self.size, self.res = self.manifest["tile_size"], self.manifest["resolution"]
        self.spacing = self.manifest["sample_spacing_m"]
        self.tiles = {(item["x"], item["z"]): np.fromfile(root / item["file"], dtype="<f4").reshape(self.res, self.res)
                      for item in self.manifest["tiles"]}

    def __call__(self, x: float, z: float) -> float:
        tx, tz = math.floor(x / self.size), math.floor(z / self.size)
        tile = self.tiles.get((tx, tz))
        if tile is None:
            raise ValueError(f"DEM does not cover road coordinate {(x, z)}")
        fx, fz = (x - tx * self.size) / self.spacing, (z - tz * self.size) / self.spacing
        ix, iz = min(int(fx), self.res - 2), min(int(fz), self.res - 2)
        u, v = fx - ix, fz - iz
        a, b, c, d = map(float, (tile[iz, ix], tile[iz, ix + 1], tile[iz + 1, ix], tile[iz + 1, ix + 1]))
        if u + v <= 1:
            return a + (b - a) * u + (c - a) * v
        return d + (c - d) * (1 - u) + (b - d) * (1 - v)

    def conform_polygon(self, polygon):
        """Split a ribbon on the same grid triangles used by terrain physics.

        Sampling only road endpoints can bury a road between them. Each output
        polygon lies in one terrain triangle, so its entire surface matches
        terrain, including both sides of every national tile seam.
        """
        from road_graph import clip_polygon, polygon_area
        step = self.spacing

        def diagonal(points, limit, lower):
            result = []
            previous = points[-1]
            before = previous[0] + previous[2] - limit
            previous_in = before <= 0 if lower else before >= 0
            for current in points:
                after = current[0] + current[2] - limit
                current_in = after <= 0 if lower else after >= 0
                if previous_in != current_in:
                    t = before / (before - after)
                    result.append(tuple(previous[i] + t * (current[i] - previous[i]) for i in range(len(previous))))
                if current_in:
                    result.append(current)
                previous, before, previous_in = current, after, current_in
            clean = []
            for point in result:
                point = (round(point[0], 6), round(self(point[0], point[2]), 6), round(point[2], 6),
                         *(round(attribute, 6) for attribute in point[3:]))
                if not clean or point != clean[-1]:
                    clean.append(point)
            if len(clean) > 1 and clean[0] == clean[-1]:
                clean.pop()
            return clean if len(clean) >= 3 and polygon_area(clean) > 1e-6 else []

        for iz in range(math.floor(min(p[2] for p in polygon) / step),
                        math.floor(max(p[2] for p in polygon) / step) + 1):
            for ix in range(math.floor(min(p[0] for p in polygon) / step),
                            math.floor(max(p[0] for p in polygon) / step) + 1):
                cell = clip_polygon(polygon, ix, iz, step)
                if not cell:
                    continue
                limit = (ix + iz + 1) * step
                for lower in (True, False):
                    surface = diagonal(cell, limit, lower)
                    if surface:
                        yield surface


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source_dir", type=Path)
    parser.add_argument("roads_manifest", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--acquire", action="store_true")
    args = parser.parse_args()
    if args.acquire:
        acquire(args.source_dir)
    m = compile_terrain(args.source_dir, args.roads_manifest, args.output)
    print("YARDMAN_TERRAIN_COMPILE_PASS", len(m["tiles"]), "tiles; peak", m["max_height"], "metres; shared edges exact")
