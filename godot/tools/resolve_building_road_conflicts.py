#!/usr/bin/env python3
"""Conservatively remove severe ground-building intrusions into road carriageways."""
from __future__ import annotations
import argparse,gzip,json,math,shutil
from functools import lru_cache
from pathlib import Path
import shapely
from shapely.geometry import LineString,Polygon
from shapely.geometry.polygon import orient
from shapely.strtree import STRtree
from build_buildings import CELL_SIZE,HEADER,INDEX,MAGIC,conform_ring,write_pack
from build_terrain import TerrainSampler

CLEARANCE_MARGIN_M=.25
MIN_INTRUSION_DEPTH_M=.75
MIN_INTERSECTION_AREA_M2=.75
MIN_RETAINED_AREA_RATIO=.68
MIN_REBUILT_AREA_M2=1.0
MAX_UNRESOLVED_EXAMPLES=200
ELEVATED_EPSILON_M=.05
EXEMPT_BUILDING_TYPES={"roof","carport","bridge"}
ROOF_AREA_REL_TOL=1e-6
ROOF_AREA_ABS_TOL=1e-4


def read_pack(path):
    with path.open("rb") as h:
        magic,count=HEADER.unpack(h.read(HEADER.size))
        if magic!=MAGIC or count>256: raise ValueError(f"Invalid building pack header: {path}")
        size=path.stat().st_size; data_start=HEADER.size+count*INDEX.size; entries=[]
        for _ in range(count):
            x,z,offset,length=INDEX.unpack(h.read(INDEX.size))
            if offset<data_start or offset+length>size: raise ValueError(f"Invalid building cell index: {path}")
            entries.append((x,z,offset,length))
        cells=[]
        for x,z,offset,length in entries:
            h.seek(offset); records=json.loads(gzip.decompress(h.read(length)))
            if not isinstance(records,list): raise ValueError(f"Building cell is not a record list: {path}")
            cells.append((x,z,records))
        return cells


def _closed_ring(points):
    r=list(points)
    if r and r[0]!=r[-1]: r.append(r[0])
    return r


def polygon_parts(g):
    if g.is_empty:return []
    if isinstance(g,Polygon):return [g]
    return [p for p in getattr(g,"geoms",[]) if isinstance(p,Polygon) and p.area>=MIN_REBUILT_AREA_M2]


def record_polygon(record,cell_x,cell_z):
    if not isinstance(record,list) or len(record) not in {8,9}: raise ValueError("Unsupported building record")
    rings=record[5]
    if not rings or len(rings[0])<3: raise ValueError("Building record has no valid footprint ring")
    ox,oz=cell_x*CELL_SIZE,cell_z*CELL_SIZE
    converted=[_closed_ring((ox+float(p[0]),oz+float(p[2])) for p in ring) for ring in rings]
    poly=Polygon(converted[0],converted[1:])
    if not poly.is_valid: poly=shapely.make_valid(poly)
    parts=polygon_parts(poly)
    if not parts: raise ValueError("Building footprint could not be reconstructed")
    return max(parts,key=lambda p:p.area)


def base_offset_from_form(form):
    try:
        v=float(form.get("min_height_m",0));
        if math.isfinite(v) and v>0:return v
    except (TypeError,ValueError):pass
    try:
        v=float(form.get("min_level",0));
        if math.isfinite(v) and v>0:return v*3.15
    except (TypeError,ValueError):pass
    return 0.0


def exempt_record(record):
    form=record[8] if len(record)==9 and isinstance(record[8],dict) else {}
    if base_offset_from_form(form)>ELEVATED_EPSILON_M:return True
    return str(form.get("building_type",form.get("building_part_type",""))).strip().lower() in EXEMPT_BUILDING_TYPES


def road_conflicts(poly,candidates,tree):
    if tree is None or poly.is_empty:return []
    out=[];seen=set()
    for raw in tree.query(poly,predicate="intersects"):
        road=candidates[int(raw)];key=road["key"]
        if key in seen:continue
        inter=poly.intersection(road["surface"])
        if inter.is_empty or inter.area<MIN_INTERSECTION_AREA_M2:continue
        if road["width_m"]*.5-road["centerline"].distance(poly)<MIN_INTRUSION_DEPTH_M:continue
        seen.add(key);out.append(road)
    return out


def resolve_polygon_conflict(poly,conflicts):
    if not conflicts:return poly,False,False,0.0
    exclusion=shapely.union_all([r["surface"].buffer(CLEARANCE_MARGIN_M,join_style=2) for r in conflicts])
    clipped=poly.difference(exclusion)
    if not clipped.is_valid:clipped=shapely.make_valid(clipped)
    parts=polygon_parts(clipped)
    # A severe carriageway conflict that cannot be reconstructed safely is not
    # allowed to survive as the original road-blocking footprint. An empty
    # result marks it for omission from runtime building packs.
    if not parts:return Polygon(),False,True,0.0
    largest=max(parts,key=lambda p:p.area); retained=largest.area/poly.area if poly.area>0 else 0; removed=max(0.,poly.area-largest.area)
    if retained<MIN_RETAINED_AREA_RATIO or largest.area<MIN_REBUILT_AREA_M2:return Polygon(),False,True,0.0
    if removed<MIN_INTERSECTION_AREA_M2:return poly,False,False,0.0
    return largest,True,False,removed


def triangulate_roof(poly):
    """Return only covered triangles and require them to cover the clipped footprint."""
    triangles=shapely.constrained_delaunay_triangles(poly)
    valid=[]
    for tri in triangles.geoms:
        if tri.area<=1e-8:continue
        # Numerical CDT slivers may straddle a boundary. Never emit them.
        if poly.covers(tri):valid.append(tri)
    if not valid:raise ValueError("Road-adjusted footprint has no valid roof triangles")
    roof=shapely.union_all(valid)
    missing=max(0.0,poly.area-roof.intersection(poly).area)
    tolerance=max(ROOF_AREA_ABS_TOL,poly.area*ROOF_AREA_REL_TOL)
    if missing>tolerance:
        raise ValueError(f"Road-adjusted roof coverage incomplete: missing={missing:.6f}m2 tolerance={tolerance:.6f}m2")
    return valid


def rebuild_record(record,poly,sampler,cell_x,cell_z,removed_area):
    poly=orient(poly,sign=1.0);ox,oz=cell_x*CELL_SIZE,cell_z*CELL_SIZE;spacing=float(getattr(sampler,"spacing",64.0))
    rings=[conform_ring(poly.exterior.coords,sampler,spacing)]+[conform_ring(r.coords,sampler,spacing) for r in poly.interiors]
    roof_y=round(max(p[1] for ring in rings for p in ring)+float(record[1]),5)
    vertices=[];indices=[];vertex_map={}
    for tri in triangulate_roof(poly):
        ti=[]
        for x,z in list(tri.exterior.coords)[:3]:
            key=(round(x-ox,4),round(z-oz,4))
            if key not in vertex_map:vertex_map[key]=len(vertices);vertices.append(list(key))
            ti.append(vertex_map[key])
        a,b,c=[vertices[i] for i in ti]
        if (b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0])>0:ti[1],ti[2]=ti[2],ti[1]
        indices.extend(ti)
    local=[[[round(x-ox,4),y,round(z-oz,4)] for x,y,z in ring] for ring in rings]
    form=dict(record[8]) if len(record)==9 and isinstance(record[8],dict) else {}
    form.update({"road_clearance_adjusted":True,"road_clearance_removed_m2":round(removed_area,3),"road_clearance_policy":"compiled_carriageway_edge_conflict"})
    return [record[0],record[1],record[2],record[3],roof_y,local,vertices,indices,form]


def load_road_tile(path):
    if not path.exists():return []
    payload=json.loads(path.read_text());roads=[]
    for s in payload.get("segments",[]):
        if not isinstance(s,list) or len(s)<12:continue
        flags=int(s[6])
        if flags&2 or flags&4:continue
        try:width=float(s[4]);a=(float(s[0]),float(s[1]));b=(float(s[2]),float(s[3]));surface=Polygon([(float(p[0]),float(p[2])) for p in s[11]])
        except (TypeError,ValueError,IndexError):continue
        if not math.isfinite(width) or width<=0 or a==b or surface.is_empty or surface.area<=1e-6:continue
        if not surface.is_valid:
            surface=shapely.make_valid(surface);parts=polygon_parts(surface)
            if not parts:continue
            surface=max(parts,key=lambda p:p.area)
        roads.append({"surface":surface,"centerline":LineString([a,b]),"width_m":width,"key":(str(s[7]) if len(s)>7 else "",int(s[8]) if len(s)>8 else 0)})
    return roads


def compile_clearance(roads_root,terrain_root,buildings_root):
    rm=json.loads((roads_root/"manifest.json").read_text());bmp=buildings_root/"manifest.json";bm=json.loads(bmp.read_text())
    rts=float(rm.get("tile_size",0));bts=float(bm.get("tile_size",0))
    if not math.isclose(rts,bts,abs_tol=1e-6):raise ValueError("Road/building tile-size mismatch")
    if not math.isclose(bts,4096.,abs_tol=1e-6):raise ValueError("Road-clearance pass expects 4096m national tiles")
    sampler=TerrainSampler(terrain_root);road_files={(int(t["x"]),int(t["z"])):str(t["file"]) for t in rm.get("tiles",[])}
    @lru_cache(maxsize=96)
    def cached(tx,tz):
        f=road_files.get((tx,tz));return load_road_tile(roads_root/f) if f else []
    radius=max(1,int(math.ceil(float(bm.get("max_footprint_reach_m",0) or 0)/bts)))
    stats={"records_seen":0,"elevated_or_grade_separated_buildings_skipped":0,"records_with_severe_carriageway_intrusion":0,"adjusted_buildings":0,"unresolved_conflicts":0,"dropped_unresolved_buildings":0,"roof_rebuild_failures":0,"removed_building_area_m2":0.0,"tiles_rewritten":0};examples=[]
    staging=buildings_root.with_name(buildings_root.name+".roadclearance")
    if staging.exists():shutil.rmtree(staging)
    staging.mkdir(parents=True);known={str(t["file"]) for t in bm.get("tiles",[])}
    for child in buildings_root.iterdir():
        if child.name=="manifest.json" or child.name in known:continue
        target=staging/child.name
        shutil.copytree(child,target) if child.is_dir() else shutil.copy2(child,target)
    for tile in bm.get("tiles",[]):
        tx,tz,fn=int(tile["x"]),int(tile["z"]),str(tile["file"]);candidates=[]
        for rz in range(tz-radius,tz+radius+1):
            for rx in range(tx-radius,tx+radius+1):candidates.extend(cached(rx,rz))
        tree=STRtree([r["surface"] for r in candidates]) if candidates else None;cells=[];changed_tile=False
        for lx,lz,records in read_pack(buildings_root/fn):
            cx,cz=tx*16+lx,tz*16+lz;rewritten=[]
            for record in records:
                stats["records_seen"]+=1
                if exempt_record(record):stats["elevated_or_grade_separated_buildings_skipped"]+=1;rewritten.append(record);continue
                poly=record_polygon(record,cx,cz);conflicts=road_conflicts(poly,candidates,tree)
                if not conflicts:rewritten.append(record);continue
                stats["records_with_severe_carriageway_intrusion"]+=1;adjusted,changed,unresolved,removed=resolve_polygon_conflict(poly,conflicts)
                reason=None
                if unresolved:reason="ambiguous_or_destructive_clip"
                elif changed:
                    try:new_record=rebuild_record(record,adjusted,sampler,cx,cz,removed)
                    except ValueError as exc:reason=f"roof_rebuild:{exc}";stats["roof_rebuild_failures"]+=1
                    else:record=new_record;stats["adjusted_buildings"]+=1;stats["removed_building_area_m2"]+=removed;changed_tile=True
                if reason:
                    stats["unresolved_conflicts"]+=1;stats["dropped_unresolved_buildings"]+=1;changed_tile=True
                    if len(examples)<MAX_UNRESOLVED_EXAMPLES:examples.append({"building_id":str(record[0]),"tile":[tx,tz],"cell":[cx,cz],"area_m2":round(poly.area,3),"reason":reason,"runtime_action":"omitted","road_keys":[list(r["key"]) for r in conflicts[:8]]})
                    # Severe ground-level road intrusions are less truthful in the
                    # runtime if preserved than if omitted. Keep the source/report
                    # evidence, but never render the unresolved obstruction.
                    continue
                rewritten.append(record)
            raw=json.dumps(rewritten,separators=(",",":"),allow_nan=False).encode();cells.append((lx,lz,gzip.compress(raw,compresslevel=6,mtime=0)))
        write_pack(staging/fn,cells)
        if changed_tile:stats["tiles_rewritten"]+=1
    stats["removed_building_area_m2"]=round(stats["removed_building_area_m2"],3);bm["record_format"]=max(2,int(bm.get("record_format",1)))
    bm["road_clearance"]={"policy":"Only severe ground-origin intersections with compiled non-bridge/non-tunnel carriageway ribbons are eligible. Shallow roadside contact is preserved. Adjustments require one dominant footprint retaining at least 68% of registered area. Severe conflicts that cannot be reconstructed safely, including incomplete rebuilt roofs, are omitted from runtime packs and retained in the clearance report instead of being rendered through the road.","clearance_margin_m":CLEARANCE_MARGIN_M,"minimum_intrusion_depth_m":MIN_INTRUSION_DEPTH_M,"minimum_intersection_area_m2":MIN_INTERSECTION_AREA_M2,"minimum_retained_area_ratio":MIN_RETAINED_AREA_RATIO,"unresolved_examples_file":"road_clearance_report.json"}
    bm.setdefault("stats",{}).update({"road_clearance_adjusted_buildings":stats["adjusted_buildings"],"road_clearance_unresolved_conflicts":stats["unresolved_conflicts"],"road_clearance_dropped_unresolved_buildings":stats["dropped_unresolved_buildings"],"road_clearance_roof_rebuild_failures":stats["roof_rebuild_failures"],"road_clearance_removed_area_m2":stats["removed_building_area_m2"]})
    (staging/"manifest.json").write_text(json.dumps(bm,indent=2,sort_keys=True));(staging/"road_clearance_report.json").write_text(json.dumps({"stats":stats,"unresolved_examples":examples},indent=2,sort_keys=True))
    backup=buildings_root.with_name(buildings_root.name+".pre-roadclearance")
    if backup.exists():shutil.rmtree(backup)
    buildings_root.replace(backup);staging.replace(buildings_root);shutil.rmtree(backup);return stats


def main():
    p=argparse.ArgumentParser();p.add_argument("roads",type=Path);p.add_argument("terrain",type=Path);p.add_argument("buildings",type=Path);a=p.parse_args();stats=compile_clearance(a.roads,a.terrain,a.buildings);print("YARDMAN_BUILDING_ROAD_CLEARANCE_PASS",json.dumps(stats,sort_keys=True),flush=True);return 0
if __name__=="__main__":raise SystemExit(main())