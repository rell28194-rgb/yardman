#!/usr/bin/env python3
"""Compile OSM coastline into exact, streamed land/water/beach geometry.

DEM height is not a land classifier. The coastline owns the horizontal land
extent, and clipped vertices use the same two height triangles as the terrain.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import math
import shutil
from pathlib import Path

import numpy as np
import shapely
from shapely.geometry import MultiLineString, Polygon, box
from shapely.ops import polygonize_full
from shapely.strtree import STRtree
from pyproj import Transformer

ATTRIBUTION = "© OpenStreetMap contributors — https://www.openstreetmap.org/copyright (ODbL)"


def read_geography(pbf: Path, origin: dict):
    """Use original OSM coast ways and assembled natural=beach multipolygons."""
    import osmium
    project = Transformer.from_crs(4326, 3448, always_xy=True)
    e0, n0 = float(origin["easting"]), float(origin["northing"])

    def project_geometry(x, y, z=None):
        e, n = project.transform(x, y)
        return np.asarray(e) - e0, n0 - np.asarray(n)

    class Reader(osmium.SimpleHandler):
        def __init__(self):
            super().__init__()
            self.lines, self.beaches, self.coast_ids, self.beach_ids = [], [], [], []
            self.factory = osmium.geom.WKBFactory()

        def way(self, way):
            if way.tags.get("natural") != "coastline":
                return
            if any(not node.location.valid() for node in way.nodes):
                raise ValueError(f"Coast way {way.id} has missing source coordinates")
            coordinates = [(node.lon, node.lat) for node in way.nodes]
            if len(coordinates) < 2:
                raise ValueError(f"Coast way {way.id} has fewer than two nodes")
            lon, lat = zip(*coordinates)
            east, north = project.transform(lon, lat)
            self.lines.append([(round(e - e0, 6), round(n0 - n, 6)) for e, n in zip(east, north)])
            self.coast_ids.append(int(way.id))

        def area(self, area):
            if area.tags.get("natural") != "beach":
                return
            geographic = shapely.from_wkb(self.factory.create_multipolygon(area))
            geometry = shapely.make_valid(shapely.transform(geographic, project_geometry, interleaved=False))
            self.beaches.append(geometry)
            self.beach_ids.append(int(area.orig_id()))

    reader = Reader()
    if pbf.suffix == ".gz":
        with gzip.open(pbf, "rb") as source:
            reader.apply_buffer(source.read(), "pbf", locations=True)
    else:
        reader.apply_file(str(pbf), locations=True)
    if not reader.lines:
        raise ValueError("Source contains no coastline")
    lines = MultiLineString(reader.lines)
    polygons, cuts, dangles, invalid = polygonize_full(lines)
    if not cuts.is_empty or not dangles.is_empty or not invalid.is_empty:
        raise ValueError("Coastline is not closed: cuts=%d dangles=%d invalid=%d" %
                         (len(shapely.get_parts(cuts)), len(shapely.get_parts(dangles)), len(shapely.get_parts(invalid))))
    # build_area preserves nested water holes; simply unioning polygonized
    # rings would fill those holes and put terrain across lagoons.
    land = shapely.build_area(lines)
    if land.is_empty or not land.is_valid:
        raise ValueError("Coastline did not form valid land polygons")
    beaches = shapely.union_all(reader.beaches) if reader.beaches else Polygon()
    return land, beaches, {"coast_ways": len(reader.coast_ids),
                           "closed_land_rings": len(shapely.get_parts(polygons)),
                           "beach_areas": len(reader.beach_ids),
                           "coast_way_ids_sha256": hashlib.sha256(json.dumps(sorted(reader.coast_ids)).encode()).hexdigest(),
                           "beach_osm_ids": sorted(reader.beach_ids)}


def _triangles(geometry):
    if geometry.is_empty:
        return
    for part in shapely.get_parts(geometry):
        if part.geom_type not in ("Polygon", "MultiPolygon") or part.area <= 1e-8:
            continue
        # Constrained triangulation honours holes and concave shorelines.
        for triangle in shapely.get_parts(shapely.constrained_delaunay_triangles(part)):
            if triangle.area > 1e-8:
                points = list(triangle.exterior.coords)[:3]
                area = sum(points[i][0] * points[(i+1) % 3][1] - points[(i+1) % 3][0] * points[i][1] for i in range(3))
                if area > 0:
                    points.reverse()  # Upward Godot winding in X/Z coordinates.
                yield points


def _append_conformed(output, geometry, x0, z0, step, a, b, c, d, lower, ox, oz):
    for points in _triangles(geometry):
        for x, z in points:
            u, v = (x-x0)/step, (z-z0)/step
            y = a + (b-a)*u + (c-a)*v if lower else d + (c-d)*(1-u) + (b-d)*(1-v)
            output.append((x-ox, y, z-oz))


def _conform_cell(output, geometry, ix, iz, heights, ox, oz, step):
    x0, z0 = ox + ix*step, oz + iz*step
    a, b, c, d = map(float, (heights[iz, ix], heights[iz, ix+1], heights[iz+1, ix], heights[iz+1, ix+1]))
    lower = Polygon([(x0,z0),(x0+step,z0),(x0,z0+step)])
    upper = Polygon([(x0+step,z0),(x0+step,z0+step),(x0,z0+step)])
    _append_conformed(output, geometry.intersection(lower), x0,z0,step,a,b,c,d,True,ox,oz)
    _append_conformed(output, geometry.intersection(upper), x0,z0,step,a,b,c,d,False,ox,oz)


def classify_grid(land, heights, ox: float, oz: float, step: float, beaches=None):
    """0 water, 1 full land cell, 2 coast-clipped partial land cell.

    Return row-major masks and flat local XYZ vertices for partial land and
    sourced beach triangles. Cells are classified in vectorized GEOS calls;
    only boundary cells perform scalar clipping.
    """
    if heights.ndim != 2 or min(heights.shape) < 2 or not np.isfinite(heights).all():
        raise ValueError("Invalid coastal DEM grid")
    if not math.isfinite(step) or step <= 0 or not all(map(math.isfinite,(ox,oz))):
        raise ValueError("Invalid coastal grid coordinates")
    depth, width = heights.shape
    tile_box = box(ox,oz,ox+(width-1)*step,oz+(depth-1)*step)
    mask = np.zeros((depth-1,width-1), dtype=np.uint8)
    partial, sand = [], []
    if land.covers(tile_box):
        mask.fill(1)
        local_land = tile_box
    elif land.disjoint(tile_box):
        local_land = Polygon()
    else:
        local_land = land.intersection(tile_box)
        xx, zz = np.meshgrid(np.arange(width-1)*step+ox,np.arange(depth-1)*step+oz)
        cells = shapely.box(xx.ravel(),zz.ravel(),xx.ravel()+step,zz.ravel()+step)
        covers = shapely.covers(local_land,cells)
        touches = shapely.intersects(local_land,cells)
        mask.ravel()[covers] = 1
        for cell_index in np.flatnonzero(touches & ~covers):
            geometry = local_land.intersection(cells[cell_index])
            if geometry.area <= 1e-8:
                continue
            iz, ix = divmod(int(cell_index),width-1)
            mask[iz,ix] = 2
            _conform_cell(partial, geometry, ix,iz,heights,ox,oz,step)
    if beaches is not None and not beaches.is_empty and beaches.intersects(tile_box):
        local_beach = beaches.intersection(local_land)
        if not local_beach.is_empty:
            minx,minz,maxx,maxz = local_beach.bounds
            for iz in range(max(0,math.floor((minz-oz)/step)), min(depth-2,math.floor((maxz-oz)/step))+1):
                for ix in range(max(0,math.floor((minx-ox)/step)), min(width-2,math.floor((maxx-ox)/step))+1):
                    patch = local_beach.intersection(box(ox+ix*step,oz+iz*step,ox+(ix+1)*step,oz+(iz+1)*step))
                    if patch.area > 1e-8:
                        _conform_cell(sand,patch,ix,iz,heights,ox,oz,step)
    return mask, np.asarray(partial,dtype="<f4").reshape(-1,3), np.asarray(sand,dtype="<f4").reshape(-1,3)


class ShoreDistances:
    def __init__(self, land):
        sections = []
        for ring in shapely.get_parts(shapely.boundary(land)):
            coordinates = list(ring.coords)
            for index in range(0,len(coordinates)-1,64):
                sections.append(shapely.LineString(coordinates[index:index+65]))
        self.tree = STRtree(sections)
        # A narrow, actual distance belt owns the coastal colour transition.
        # Clamping samples on a 512m triangle would otherwise spread a 40m
        # transition across that whole triangle, producing triangular shallows.
        self.belt = land.buffer(40.0, quad_segs=8).difference(land)

    def values(self, points):
        if len(points) == 0:
            return np.empty(0)
        indices, distances = self.tree.query_nearest(shapely.points(points),return_distance=True,all_matches=False)
        result = np.empty(len(points))
        result[indices[0]] = np.minimum(distances,40.0)
        return result


def _water_grid_points(geometry, extent, grid_spacing):
    """Clip one independent flat ocean layer to a globally aligned grid."""
    if geometry.is_empty:
        return []
    shapely.prepare(geometry)
    minx,minz,maxx,maxz = extent.bounds
    xs = np.arange(math.floor(minx/grid_spacing),math.ceil(maxx/grid_spacing))*grid_spacing
    zs = np.arange(math.floor(minz/grid_spacing),math.ceil(maxz/grid_spacing))*grid_spacing
    xx,zz = np.meshgrid(xs,zs)
    cells = shapely.box(np.maximum(xx.ravel(),minx),np.maximum(zz.ravel(),minz),
                        np.minimum(xx.ravel()+grid_spacing,maxx),np.minimum(zz.ravel()+grid_spacing,maxz))
    full = shapely.covers(geometry,cells)
    intersects = shapely.intersects(geometry,cells)
    points = []
    for index in np.flatnonzero(full):
        x0,z0,x1,z1 = cells[index].bounds
        points.extend(((x0,z0),(x0,z1),(x1,z0),(x1,z0),(x0,z1),(x1,z1)))
    for index in np.flatnonzero(intersects & ~full):
        points.extend(point for triangle in _triangles(geometry.intersection(cells[index])) for point in triangle)
    return points


def _nearshore_grid_points(geometry, extent, grid_spacing, block_spacing=512.0):
    """Prepare a caller-selected coast grid in bounded blocks.

    Allocating a full island-sized 16m grid would create roughly 92 million
    boxes. Only coastal 512m blocks prepare their own small fine-grid batch.
    """
    if geometry.is_empty:
        return []
    shapely.prepare(geometry)
    minx,minz,maxx,maxz = extent.bounds
    xs = np.arange(math.floor(minx/block_spacing),math.ceil(maxx/block_spacing))*block_spacing
    zs = np.arange(math.floor(minz/block_spacing),math.ceil(maxz/block_spacing))*block_spacing
    xx,zz = np.meshgrid(xs,zs)
    blocks = shapely.box(np.maximum(xx.ravel(),minx),np.maximum(zz.ravel(),minz),
                         np.minimum(xx.ravel()+block_spacing,maxx),np.minimum(zz.ravel()+block_spacing,maxz))
    points = []
    for index in np.flatnonzero(shapely.intersects(geometry, blocks)):
        patch = geometry.intersection(blocks[index])
        if not patch.is_empty:
            points.extend(_water_grid_points(patch, blocks[index], grid_spacing))
    return points


def water_geometry(land, extent, shore: ShoreDistances, ox,oz,grid_spacing=512.0,coastal_spacing=16.0):
    geometry = extent.difference(land)
    if geometry.is_empty:
        return np.empty((0,4),dtype="<f4")
    coastal = geometry.intersection(shore.belt)
    offshore = geometry.difference(shore.belt)
    points = _water_grid_points(offshore, extent, grid_spacing)
    offshore_vertex_count = len(points)
    points.extend(_nearshore_grid_points(coastal, extent, coastal_spacing))
    if not points:
        return np.empty((0,4),dtype="<f4")
    points = np.asarray(points,dtype=np.float64)
    distances = shore.values(points)
    # Polygon buffers approximate round joins with chords. A chord vertex can
    # lie a fraction of a metre inside the true forty-metre distance, but its
    # offshore triangle may span hundreds of metres. The offshore layer owns
    # only deep colour; do not let that tiny buffer error stretch a coastal tint
    # through a coarse offshore triangle.
    distances[:offshore_vertex_count] = 40.0
    # Concave bays can have three shore vertices but deep water inside. Add an
    # interior sample there instead of colouring the whole bay as shoreline.
    triangles = points.reshape(-1,3,2)
    needs_center = np.max(distances.reshape(-1,3),axis=1) < 2.0
    areas = np.abs((triangles[:,1,0]-triangles[:,0,0])*(triangles[:,2,1]-triangles[:,0,1]) -
                   (triangles[:,2,0]-triangles[:,0,0])*(triangles[:,1,1]-triangles[:,0,1]))*.5
    needs_center &= areas > 100.0
    if np.any(needs_center):
        centers = triangles[needs_center].mean(axis=1)
        center_distances = iter(shore.values(centers))
        new_points,new_distances = [],[]
        for index,triangle in enumerate(triangles):
            samples = distances[index*3:index*3+3]
            if not needs_center[index]:
                new_points.extend(triangle)
                new_distances.extend(samples)
                continue
            center,center_distance = triangle.mean(axis=0),next(center_distances)
            for vertex in range(3):
                other = (vertex+1)%3
                new_points.extend((triangle[vertex],triangle[other],center))
                new_distances.extend((samples[vertex],samples[other],center_distance))
        points,distances = np.asarray(new_points),np.asarray(new_distances)
    return np.column_stack((points[:,0]-ox,np.zeros(len(points)),points[:,1]-oz,distances)).astype("<f4")


def compile_coastline(pbf: Path, terrain_root: Path, output: Path, geography=None):
    terrain = json.loads((terrain_root/"manifest.json").read_text())
    if terrain["crs"] != "EPSG:3448":
        raise ValueError("Coastline requires canonical EPSG:3448 terrain")
    land, beaches, source_stats = geography or read_geography(pbf,terrain["origin"])
    if geography is None and not 10000e6 < land.area < 12000e6:
        raise ValueError(f"Unexpected Jamaica land area: {land.area/1e6:.1f} km²")
    shapely.prepare(land)
    shore = ShoreDistances(land)
    staging = output.with_name(output.name+".staging")
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    size, res, step = float(terrain["tile_size"]), int(terrain["resolution"]), float(terrain["sample_spacing_m"])
    entries = []
    stats = {"water_cells":0,"land_cells":0,"partial_cells":0,"partial_land_triangles":0,"water_triangles":0,"beach_triangles":0}
    for item in sorted(terrain["tiles"],key=lambda v:(v["z"],v["x"])):
        tx,tz = int(item["x"]),int(item["z"])
        ox,oz = tx*size,tz*size
        heights = np.fromfile(terrain_root/item["file"],dtype="<f4").reshape(res,res)
        mask,partial,sand = classify_grid(land,heights,ox,oz,step,beaches)
        water = water_geometry(land,box(ox,oz,ox+size,oz+size),shore,ox,oz)
        names = {"mask":f"mask_{tx}_{tz}.bin","land":f"land_{tx}_{tz}.bin",
                 "water":f"water_{tx}_{tz}.bin","beach":f"beach_{tx}_{tz}.bin"}
        for key,values in (("mask",mask),("land",partial),("water",water),("beach",sand)):
            (staging/names[key]).write_bytes(values.tobytes())
        entry = {"x":tx,"z":tz,**names,"land_triangles":len(partial)//3,"water_triangles":len(water)//3,"beach_triangles":len(sand)//3}
        entries.append(entry)
        for key,value in zip(("water_cells","land_cells","partial_cells"),np.bincount(mask.ravel(),minlength=3)):
            stats[key] += int(value)
        for key,count in (("partial_land_triangles",len(partial)//3),("water_triangles",len(water)//3),("beach_triangles",len(sand)//3)):
            stats[key] += count
    overview = terrain.get("overview")
    overview_files = {}
    if overview:
        heights = np.fromfile(terrain_root/overview["file"],dtype="<f4").reshape(overview["depth"],overview["width"])
        ox,oz,step = float(overview["origin_x"]),float(overview["origin_z"]),float(overview["spacing"])
        mask,partial,_ = classify_grid(land,heights,ox,oz,step)
        water = water_geometry(land,box(ox,oz,ox+(heights.shape[1]-1)*step,oz+(heights.shape[0]-1)*step),shore,ox,oz,
                               coastal_spacing=64.0)
        for key,values in (("mask",mask),("land",partial),("water",water)):
            filename = "overview_"+key+".bin"
            (staging/filename).write_bytes(values.tobytes())
            overview_files[key] = filename
        overview_files.update({k:overview[k] for k in ("origin_x","origin_z","width","depth","spacing")})
    source_hash = hashlib.sha256()
    source_open = gzip.open if pbf.suffix == ".gz" else open
    with source_open(pbf,"rb") as source:
        while chunk := source.read(1024*1024):
            source_hash.update(chunk)
    manifest = {"format":1,"crs":"EPSG:3448","origin":terrain["origin"],"tile_size":size,
                "resolution":res,"sample_spacing_m":float(terrain["sample_spacing_m"]),
                "axis":"X east, Y elevation, Z south; real metres","sea_level_m":0.0,
                "source":"OpenStreetMap natural=coastline and natural=beach",
                "source_sha256":source_hash.hexdigest(),"attribution":ATTRIBUTION,
                "land_area_km2":land.area/1e6,"land_bounds":list(land.bounds),"source_stats":source_stats,
                "terrain_manifest_sha256":hashlib.sha256((terrain_root/"manifest.json").read_bytes()).hexdigest(),
                "mask_encoding":"uint8 row-major (resolution-1)^2: 0 water, 1 full land, 2 partial land",
                "land_encoding":"little-endian float32, triangle-list local XYZ metres",
                "water_encoding":"little-endian float32, triangle-list local X, sea Y=0, Z, shore distance clamped to 40m",
                "water_mesh":{"offshore_grid_m":512.0,"coastal_grid_m":16.0,
                              "overview_coastal_grid_m":64.0,"coastal_belt_m":40.0},
                "beach_encoding":"same XYZ terrain planes; no invented beach belt",
                "tiles":entries,"overview":overview_files,"stats":stats,
                "limitations":["OSM coastline and beach completeness require geographic validation","Visual shore-distance colour is not measured bathymetry","Copernicus DSM heights may include canopy/structures at the coast"]}
    (staging/"manifest.json").write_text(json.dumps(manifest,indent=2,sort_keys=True))
    if output.exists():
        shutil.rmtree(output)
    staging.replace(output)
    return manifest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source_pbf",type=Path)
    parser.add_argument("terrain_root",type=Path)
    parser.add_argument("output",type=Path)
    args = parser.parse_args()
    manifest = compile_coastline(args.source_pbf,args.terrain_root,args.output)
    print("YARDMAN_COASTLINE_COMPILE_PASS",len(manifest["tiles"]),"tiles",json.dumps(manifest["stats"],sort_keys=True))


if __name__ == "__main__":
    main()
