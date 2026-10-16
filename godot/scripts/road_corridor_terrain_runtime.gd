extends Node

# The national DEM stays geographic authority, but the 64 m near-terrain grid is
# too coarse to meet a 3-8 m road deck without occasional triangle poke-through.
# Road refinement is deliberately queued: streaming signals never synchronously
# rebuild terrain. Only tiles inside the physics warm set are refined, which keeps
# predictive/render residency cheap enough for driving and future high-speed flight.
const FLAG_BRIDGE := 2
const FLAG_TUNNEL := 4
const REFINE_STEP_M := 8.0
const EXCAVATION_MARGIN_M := 18.0
const DECK_CLEARANCE_M := 0.12
const MIN_SHOULDER_M := 0.65
const MAX_SHOULDER_M := 1.35
const INTEGRATION_INTERVAL_S := 0.06
const MAX_REFINEMENTS_PER_TICK := 1
const MAX_REFINEMENT_DISTANCE_TILES := 1

var _roads: Node
var _terrain: Node
var _connected := false
var _segments_by_tile: Dictionary = {}
var _original_mesh_by_tile: Dictionary = {}
var _pending_tiles: Dictionary = {}
var _integration_clock := 0.0
var _refinement_count := 0
var _last_refinement_us := 0
var _max_refinement_us := 0

func _ready() -> void:
    set_process(true)

func _process(delta: float) -> void:
    if not _connected:
        var scene := get_tree().current_scene
        if scene == null: return
        _roads = scene.get_node_or_null("JamaicaRoadStreamer")
        _terrain = scene.get_node_or_null("JamaicaTerrainStreamer")
        if _roads == null or _terrain == null: return
        _roads.tile_content_ready.connect(_on_road_tile)
        _roads.tile_removed.connect(_on_road_tile_removed)
        _terrain.tile_ready.connect(_on_terrain_tile)
        _terrain.tile_removed.connect(_on_terrain_tile_removed)
        _connected = true
    if _pending_tiles.is_empty(): return
    _integration_clock += delta
    if _integration_clock < INTEGRATION_INTERVAL_S: return
    _integration_clock = 0.0
    var active_tile := _active_tile()
    var tiles: Array = _pending_tiles.keys()
    tiles.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return _tile_priority(a) < _tile_priority(b))
    var processed := 0
    for tile_value in tiles:
        if processed >= MAX_REFINEMENTS_PER_TICK: break
        var tile: Vector2i = tile_value
        # Predictive streaming may keep many terrain/road tiles resident. Do not
        # spend CPU/RAM building micro terrain and concave collision for them until
        # they enter the player's physical warm neighborhood.
        if active_tile.x != 2147483647 and _tile_chebyshev_distance(tile, active_tile) > MAX_REFINEMENT_DISTANCE_TILES:
            continue
        var started_us := Time.get_ticks_usec()
        if _try_refine(tile):
            _pending_tiles.erase(tile)
            var elapsed_us := int(Time.get_ticks_usec() - started_us)
            _refinement_count += 1
            _last_refinement_us = elapsed_us
            _max_refinement_us = maxi(_max_refinement_us, elapsed_us)
            processed += 1

func _active_tile() -> Vector2i:
    if _roads == null or _terrain == null: return Vector2i(2147483647, 2147483647)
    var scene := get_tree().current_scene
    if scene == null: return Vector2i(2147483647, 2147483647)
    var player = scene.get("player"); var car = scene.get("car")
    if player == null or car == null: return Vector2i(2147483647, 2147483647)
    var active: Node3D = car if bool(player.get("in_vehicle")) else player
    var world: PackedFloat64Array = _roads.local_to_world(active.global_position)
    if world.size() < 3: return Vector2i(2147483647, 2147483647)
    return Vector2i(int(floor(float(world[0]) / float(_terrain.tile_size))), int(floor(float(world[2]) / float(_terrain.tile_size))))

func _tile_chebyshev_distance(a: Vector2i, b: Vector2i) -> int:
    return maxi(absi(a.x - b.x), absi(a.y - b.y))

func _tile_priority(tile: Vector2i) -> float:
    var active := _active_tile()
    if active.x == 2147483647: return 0.0
    var dx := float(tile.x - active.x); var dz := float(tile.y - active.y)
    return dx * dx + dz * dz

func _queue_refine(tile: Vector2i) -> void:
    _pending_tiles[tile] = true

func _on_road_tile(tile: Vector2i, _tile_root: Node3D, segments: Array) -> void:
    _segments_by_tile[tile] = segments.duplicate(false); _queue_refine(tile)
func _on_road_tile_removed(tile: Vector2i) -> void:
    _pending_tiles.erase(tile); _segments_by_tile.erase(tile); _restore_tile(tile)
func _on_terrain_tile(tile: Vector2i) -> void: _queue_refine(tile)
func _on_terrain_tile_removed(tile: Vector2i) -> void:
    _pending_tiles.erase(tile); _original_mesh_by_tile.erase(tile)
func _terrain_root(tile: Vector2i) -> Node3D:
    if _terrain == null: return null
    return _terrain.get_node_or_null("TerrainTile_%d_%d" % [tile.x, tile.y]) as Node3D

func _try_refine(tile: Vector2i) -> bool:
    if _terrain == null or not _terrain.is_tile_ready(tile) or not _segments_by_tile.has(tile): return false
    var tile_root := _terrain_root(tile)
    if tile_root == null: return false
    var land := tile_root.get_node_or_null("RegisteredLand") as MeshInstance3D
    if land == null or land.mesh == null or land.mesh.get_surface_count() == 0: return false
    var key: String = _terrain._tile_key(tile.x, tile.y)
    var heights: PackedFloat32Array = _terrain._height_data.get(key, PackedFloat32Array())
    var coast: Dictionary = _terrain._coast_data.get(key, {})
    var mask: PackedByteArray = coast.get("mask", PackedByteArray())
    if heights.size() != int(_terrain.resolution) * int(_terrain.resolution) or mask.is_empty(): return false
    if not _original_mesh_by_tile.has(tile): _original_mesh_by_tile[tile] = land.mesh
    var source_mesh: ArrayMesh = _original_mesh_by_tile[tile]
    var plan := refinement_plan(_segments_by_tile[tile], tile, float(_terrain.tile_size), float(_terrain.spacing), int(_terrain.resolution), mask)
    var cells: Dictionary = plan.get("cells", {})
    if cells.is_empty(): _restore_tile(tile); return true
    var result := rebuild_land_arrays(source_mesh, heights, cells, tile, float(_terrain.tile_size), float(_terrain.spacing), int(_terrain.resolution), REFINE_STEP_M)
    if not bool(result.get("ok", false)): push_warning("Road corridor terrain refinement failed for %s" % str(tile)); return true
    var mesh := ArrayMesh.new(); mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, result.arrays); mesh.surface_set_material(0, source_mesh.surface_get_material(0)); land.mesh = mesh
    land.set_meta("road_corridor_refined", true); land.set_meta("refined_cells", cells.size()); land.set_meta("removed_coarse_triangles", int(result.removed_triangles)); land.set_meta("micro_triangles", int(result.micro_triangles)); land.set_meta("structural_skips", int(plan.get("structural_skips", 0)))
    _replace_collision(tile_root, result.arrays); return true

func _restore_tile(tile: Vector2i) -> void:
    if not _original_mesh_by_tile.has(tile): return
    var tile_root := _terrain_root(tile)
    if tile_root == null: return
    var land := tile_root.get_node_or_null("RegisteredLand") as MeshInstance3D
    if land == null: return
    var source_mesh: ArrayMesh = _original_mesh_by_tile[tile]; land.mesh = source_mesh
    land.remove_meta("road_corridor_refined"); land.remove_meta("refined_cells"); land.remove_meta("removed_coarse_triangles"); land.remove_meta("micro_triangles"); land.remove_meta("structural_skips")
    _replace_collision(tile_root, source_mesh.surface_get_arrays(0))

func refinement_plan(segments: Array, tile: Vector2i, tile_size: float, spacing: float, resolution: int, land_mask: PackedByteArray) -> Dictionary:
    var cells: Dictionary = {}; var structural_skips := 0
    if tile_size <= 0.0 or spacing <= 0.0 or resolution < 2 or not is_finite(tile_size) or not is_finite(spacing): return {"cells": cells, "structural_skips": structural_skips}
    if land_mask.size() != (resolution - 1) * (resolution - 1): return {"cells": cells, "structural_skips": structural_skips}
    var tile_origin := Vector2(float(tile.x) * tile_size, float(tile.y) * tile_size)
    for segment in segments:
        if not segment is Array or segment.size() < 12: continue
        var flags := int(segment[6]);
        if flags & (FLAG_BRIDGE | FLAG_TUNNEL): structural_skips += 1; continue
        var polygon = segment[11]
        if not polygon is Array or polygon.size() < 3: continue
        var width := float(segment[4]);
        if not is_finite(width) or width < 1.0: continue
        var axis_start := Vector2(float(segment[0]), float(segment[1])); var axis_end := Vector2(float(segment[2]), float(segment[3]))
        var expand := width * 0.5 + clampf(width * 0.10, MIN_SHOULDER_M, MAX_SHOULDER_M) + 0.35 + EXCAVATION_MARGIN_M
        var min_x := INF; var max_x := -INF; var min_z := INF; var max_z := -INF
        for raw_point in polygon:
            if not raw_point is Array or raw_point.size() < 3: continue
            var lx := float(raw_point[0]) - tile_origin.x; var lz := float(raw_point[2]) - tile_origin.y
            min_x = minf(min_x,lx); max_x=maxf(max_x,lx); min_z=minf(min_z,lz); max_z=maxf(max_z,lz)
        if not is_finite(min_x): continue
        var x0:=clampi(int(floor((min_x-expand)/spacing)),0,resolution-2); var x1:=clampi(int(floor((max_x+expand)/spacing)),0,resolution-2); var z0:=clampi(int(floor((min_z-expand)/spacing)),0,resolution-2); var z1:=clampi(int(floor((max_z+expand)/spacing)),0,resolution-2)
        for z in range(z0,z1+1):
            for x in range(x0,x1+1):
                if land_mask[z*(resolution-1)+x] != 1: continue
                var rect:=Rect2(tile_origin+Vector2(float(x),float(z))*spacing,Vector2.ONE*spacing)
                if not _corridor_touches_cell(axis_start,axis_end,expand,rect): continue
                var ck:="%d:%d"%[x,z]
                if not cells.has(ck): cells[ck]={"cell":Vector2i(x,z),"segments":[]}
                cells[ck].segments.append(segment)
    return {"cells":cells,"structural_skips":structural_skips}

func _corridor_touches_cell(a:Vector2,b:Vector2,radius:float,cell:Rect2)->bool:
    var rs:=radius*radius+0.000001
    for p in [a,b]:
        var n:=Vector2(clampf(p.x,cell.position.x,cell.end.x),clampf(p.y,cell.position.y,cell.end.y)); if p.distance_squared_to(n)<=rs:return true
    var corners:=[cell.position,Vector2(cell.end.x,cell.position.y),cell.end,Vector2(cell.position.x,cell.end.y)]
    for i in range(4):
        var c:Vector2=corners[i]; if c.distance_squared_to(Geometry2D.get_closest_point_to_segment(c,a,b))<=rs:return true
        if Geometry2D.segment_intersects_segment(a,b,c,corners[(i+1)%4])!=null:return true
    return false

func rebuild_land_arrays(source_mesh:ArrayMesh,heights:PackedFloat32Array,cells:Dictionary,tile:Vector2i,tile_size:float,spacing:float,resolution:int,refine_step_m:float=REFINE_STEP_M)->Dictionary:
    if source_mesh==null or source_mesh.get_surface_count()==0 or cells.is_empty():return {"ok":false}
    var source:Array=source_mesh.surface_get_arrays(0); var vertices:PackedVector3Array=source[Mesh.ARRAY_VERTEX].duplicate(); var normals:PackedVector3Array=source[Mesh.ARRAY_NORMAL].duplicate(); var colors:PackedColorArray=source[Mesh.ARRAY_COLOR].duplicate(); var old_indices:PackedInt32Array=source[Mesh.ARRAY_INDEX]; var indices:=PackedInt32Array(); var removed:=0
    for cursor in range(0,old_indices.size(),3):
        if cursor+2>=old_indices.size():break
        var ia:=int(old_indices[cursor]);var ib:=int(old_indices[cursor+1]);var ic:=int(old_indices[cursor+2]);var center:=(vertices[ia]+vertices[ib]+vertices[ic])/3.0;var cx:=clampi(int(floor(center.x/spacing)),0,resolution-2);var cz:=clampi(int(floor(center.z/spacing)),0,resolution-2)
        if cells.has("%d:%d"%[cx,cz]):removed+=1;continue
        indices.append_array(PackedInt32Array([ia,ib,ic]))
    var origin:=Vector2(float(tile.x)*tile_size,float(tile.y)*tile_size);var micro:=0;var keys:Array=cells.keys();keys.sort()
    for ck in keys:
        var record:Dictionary=cells[ck];micro+=_append_refined_cell(vertices,normals,colors,indices,heights,record.cell,record.segments,origin,spacing,resolution,refine_step_m)
    var arrays:Array=[];arrays.resize(Mesh.ARRAY_MAX);arrays[Mesh.ARRAY_VERTEX]=vertices;arrays[Mesh.ARRAY_NORMAL]=normals;arrays[Mesh.ARRAY_COLOR]=colors;arrays[Mesh.ARRAY_INDEX]=indices
    return {"ok":true,"arrays":arrays,"removed_triangles":removed,"micro_triangles":micro}

func _append_refined_cell(vertices:PackedVector3Array,normals:PackedVector3Array,colors:PackedColorArray,indices:PackedInt32Array,heights:PackedFloat32Array,cell:Vector2i,segments:Array,tile_origin:Vector2,spacing:float,resolution:int,refine_step_m:float)->int:
    var subdivisions:=maxi(1,int(ceil(spacing/refine_step_m)));var step:=spacing/float(subdivisions);var side:=subdivisions+1;var sampled:=PackedFloat32Array();sampled.resize(side*side)
    for iz in range(side):
        for ix in range(side):
            var u:=float(ix)/float(subdivisions);var v:=float(iz)/float(subdivisions);var lx:=(float(cell.x)+u)*spacing;var lz:=(float(cell.y)+v)*spacing;sampled[iz*side+ix]=carved_height(_cell_height(heights,cell,u,v,resolution),tile_origin.x+lx,tile_origin.y+lz,segments)
    var base:=vertices.size()
    for iz in range(side):
        for ix in range(side):
            var lx:=float(cell.x)*spacing+float(ix)*step;var lz:=float(cell.y)*spacing+float(iz)*step;var y:=float(sampled[iz*side+ix]);vertices.append(Vector3(lx,y,lz));normals.append(Vector3.UP);colors.append(_height_color(y,0.0))
    for iz in range(subdivisions):
        for ix in range(subdivisions):
            var a:=base+iz*side+ix;var b:=a+1;var c:=a+side;var d:=c+1;indices.append_array(PackedInt32Array([a,c,b,b,c,d]))
    return subdivisions*subdivisions*2

func _cell_height(h:PackedFloat32Array,cell:Vector2i,u:float,v:float,resolution:int)->float:
    var a:=float(h[cell.y*resolution+cell.x]);var b:=float(h[cell.y*resolution+cell.x+1]);var c:=float(h[(cell.y+1)*resolution+cell.x]);var d:=float(h[(cell.y+1)*resolution+cell.x+1]);return a+(b-a)*u+(c-a)*v+(d-c-b+a)*u*v
func carved_height(raw:float,wx:float,wz:float,segments:Array)->float:
    var result:=raw;var p:=Vector2(wx,wz)
    for segment in segments:
        if not segment is Array or segment.size()<11:continue
        if int(segment[6])&(FLAG_BRIDGE|FLAG_TUNNEL):continue
        var a:=Vector2(float(segment[0]),float(segment[1]));var b:=Vector2(float(segment[2]),float(segment[3]));var delta:=b-a;var ls:=delta.length_squared();var width:=float(segment[4]);if ls<0.0025 or width<1.0:continue
        var t:=clampf((p-a).dot(delta)/ls,0.0,1.0);var distance:=p.distance_to(a+delta*t);var shoulder:=clampf(width*0.10,MIN_SHOULDER_M,MAX_SHOULDER_M);var inner:=width*0.5+shoulder+0.35;var outer:=inner+EXCAVATION_MARGIN_M
        if distance>=outer:continue
        var floor_y:=lerpf(float(segment[9]),float(segment[10]),t)-DECK_CLEARANCE_M;if result<=floor_y:continue
        var allowed:=floor_y
        if distance>inner:var blend:=clampf((distance-inner)/maxf(outer-inner,0.001),0.0,1.0);blend=blend*blend*(3.0-2.0*blend);allowed=lerpf(floor_y,raw,blend)
        result=minf(result,allowed)
    return result

func _replace_collision(tile_root:Node3D,arrays:Array)->void:
    var vertices:PackedVector3Array=arrays[Mesh.ARRAY_VERTEX];var indices:PackedInt32Array=arrays[Mesh.ARRAY_INDEX];if vertices.is_empty() or indices.is_empty():return
    var faces:=PackedVector3Array();for index in indices:faces.append(vertices[int(index)])
    var shape:=ConcavePolygonShape3D.new();shape.backface_collision=true;shape.set_faces(faces);var collider:=CollisionShape3D.new();collider.shape=shape;var body:=StaticBody3D.new();body.name="RoadAwareTerrainCollision";body.collision_layer=0;body.collision_mask=0;body.add_child(collider);tile_root.add_child(body)
    var old_body:StaticBody3D
    for child in tile_root.get_children():if child is StaticBody3D and child!=body:old_body=child as StaticBody3D;break
    var enable:=old_body!=null and old_body.collision_layer!=0;body.collision_layer=1 if enable else 0;body.set_meta("yardman_physics_active",enable);collider.set_deferred("disabled",not enable)
    if old_body!=null:tile_root.remove_child(old_body);old_body.queue_free()

func runtime_snapshot()->Dictionary:
    return {"pending_refinements":_pending_tiles.size(),"tracked_road_tiles":_segments_by_tile.size(),"refined_tiles":_original_mesh_by_tile.size(),"refinement_count":_refinement_count,"last_refinement_ms":float(_last_refinement_us)/1000.0,"max_refinement_ms":float(_max_refinement_us)/1000.0,"refinement_radius_tiles":MAX_REFINEMENT_DISTANCE_TILES}
func _height_color(height:float,slope:float)->Color:
    if height<2.0:return Color(0.38,0.43,0.25)
    return Color(0.24,0.38,0.14).lerp(Color(0.12,0.26,0.18),clampf(height/1800.0,0.0,1.0)).lerp(Color(0.48,0.43,0.34),clampf((slope-0.45)*0.8,0.0,0.65))
