extends Node

# The national DEM stays geographic authority, but the 64 m near-terrain grid is
# too coarse to meet a 3-8 m road deck without occasional triangle poke-through.
# This layer replaces only full-land DEM cells touched by a loaded road corridor
# with an 8 m micro-grid. Cut terrain is excavated beneath the stable road deck;
# fill terrain is never raised here because RoadEarthworksRuntime supplies the
# engineered shoulder/fill tie. Bridge/tunnel corridors remain structural authority.
const FLAG_BRIDGE := 2
const FLAG_TUNNEL := 4
const REFINE_STEP_M := 8.0
const EXCAVATION_MARGIN_M := 18.0
const DECK_CLEARANCE_M := 0.12
const MIN_SHOULDER_M := 0.65
const MAX_SHOULDER_M := 1.35

var _roads: Node
var _terrain: Node
var _connected := false
var _segments_by_tile: Dictionary = {}
var _original_mesh_by_tile: Dictionary = {}
var _original_root_by_tile: Dictionary = {}
var _revisions: Dictionary = {}
var _pending: Array[Vector2i] = []
var _job: Dictionary = {}
var _task_id := -1
var _completed_jobs := 0
var _cancelled_jobs := 0
var _failed_jobs := 0
var _last_worker_us := 0
var _max_main_grant_us := 0

class Cancellation extends RefCounted:
    var _mutex := Mutex.new()
    var _cancelled := false
    func cancel() -> void:
        _mutex.lock()
        _cancelled = true
        _mutex.unlock()
    func is_cancelled() -> bool:
        _mutex.lock()
        var value := _cancelled
        _mutex.unlock()
        return value

func _ready() -> void:
    set_process(true)

func _process(_delta: float) -> void:
    if _connected:
        set_process(false)
        return
    var scene := get_tree().current_scene
    if scene == null:
        return
    _roads = scene.get_node_or_null("JamaicaRoadStreamer")
    _terrain = scene.get_node_or_null("JamaicaTerrainStreamer")
    if _roads == null or _terrain == null:
        return
    _roads.tile_content_ready.connect(_on_road_tile)
    _roads.tile_removed.connect(_on_road_tile_removed)
    _terrain.tile_ready.connect(_on_terrain_tile)
    _terrain.tile_removed.connect(_on_terrain_tile_removed)
    _connected = true
    set_process(false)

func _on_road_tile(tile: Vector2i, _tile_root: Node3D, segments: Array) -> void:
    _segments_by_tile[tile] = segments.duplicate(false)
    _try_refine(tile)

func _on_road_tile_removed(tile: Vector2i) -> void:
    _segments_by_tile.erase(tile)
    _restore_tile(tile)

func _on_terrain_tile(tile: Vector2i) -> void:
    _try_refine(tile)

func _on_terrain_tile_removed(tile: Vector2i) -> void:
    _original_mesh_by_tile.erase(tile)
    _original_root_by_tile.erase(tile)
    _cancel_job_for_tile(tile)
    _revisions[tile] = int(_revisions.get(tile, 0)) + 1
    _pending.erase(tile)

func _terrain_root(tile: Vector2i) -> Node3D:
    if _terrain == null:
        return null
    return _terrain.get_node_or_null("TerrainTile_%d_%d" % [tile.x, tile.y]) as Node3D

# Signals only invalidate/queue work. Terrain owns the shared integration slice;
# CPU geometry and face expansion run on one bounded in-flight worker.
func _try_refine(tile: Vector2i) -> void:
    _queue_tile(tile)

func _cancel_job_for_tile(tile: Vector2i) -> void:
    if not _job.is_empty() and _job.tile == tile:
        _job.cancellation.cancel()

func _queue_tile(tile: Vector2i) -> void:
    _cancel_job_for_tile(tile)
    _revisions[tile] = int(_revisions.get(tile, 0)) + 1
    if not _pending.has(tile):
        _pending.append(tile)
    if is_instance_valid(_terrain) and _terrain.has_method("request_corridor_integration"):
        _terrain.request_corridor_integration(self)

func _restore_tile(tile: Vector2i) -> void:
    _queue_tile(tile)

func _exit_tree() -> void:
    if is_instance_valid(_terrain) and _terrain.has_method("cancel_corridor_integration"):
        _terrain.cancel_corridor_integration(self)
    # A worker never touches the scene, but its callable must outlive execution.
    if not _job.is_empty():
        _job.cancellation.cancel()
    if _task_id >= 0:
        WorkerThreadPool.wait_for_task_completion(_task_id)
        _task_id = -1

func runtime_snapshot() -> Dictionary:
    return {"pending_tiles": _pending.size(), "worker_in_flight": _task_id >= 0,
        "phase": "idle" if _job.is_empty() else ("cpu" if _task_id >= 0 else ("publish" if _job.has("shape") else ("shape" if _job.has("mesh") else "mesh"))),
        "completed_jobs": _completed_jobs, "cancelled_jobs": _cancelled_jobs,
        "failed_jobs": _failed_jobs, "last_worker_us": _last_worker_us,
        "max_main_grant_us": _max_main_grant_us}

func advance_terrain_integration(budget_us: int) -> bool:
    var started := Time.get_ticks_usec()
    var remains := _advance_terrain_integration(budget_us)
    _max_main_grant_us = maxi(_max_main_grant_us, Time.get_ticks_usec() - started)
    return remains

func _advance_terrain_integration(budget_us: int) -> bool:
    if budget_us <= 0:
        return not _pending.is_empty() or not _job.is_empty()
    # Do at most one indivisible Resource operation per grant. Uploading a
    # surface/physics shape is an engine call and cannot be interrupted safely.
    if not _job.is_empty():
        if _task_id >= 0:
            if not WorkerThreadPool.is_task_completed(_task_id):
                return true
            WorkerThreadPool.wait_for_task_completion(_task_id)
            _task_id = -1
            _last_worker_us = int(_job.output.get("worker_us", 0))
        if not _job_is_current(_job):
            _cancelled_jobs += 1
            _job = {}
        elif not bool(_job.output.get("ok", false)):
            _failed_jobs += 1
            push_warning("Road corridor CPU refinement failed for %s" % str(_job.tile))
            _job = {}
        elif not _job.has("mesh"):
            if bool(_job.output.restore):
                _job.mesh = _job.source_mesh
            else:
                var mesh := ArrayMesh.new()
                mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _job.output.arrays)
                mesh.surface_set_material(0, _job.source_mesh.surface_get_material(0))
                _job.mesh = mesh
            return true
        elif not _job.has("shape"):
            var shape := ConcavePolygonShape3D.new()
            shape.backface_collision = true
            shape.set_faces(_job.output.faces)
            _job.shape = shape
            return true
        else:
            if _commit_job(_job):
                _completed_jobs += 1
            else:
                _failed_jobs += 1
                push_warning("Road corridor terrain collision disappeared before commit for %s" % str(_job.tile))
            _job = {}
            return not _pending.is_empty()
    if _job.is_empty() and not _pending.is_empty():
        var tile: Vector2i = _pending.pop_front()
        _begin_job(tile)
    return not _pending.is_empty() or not _job.is_empty()

func _job_is_current(job: Dictionary) -> bool:
    if int(_revisions.get(job.tile, 0)) != int(job.revision):
        return false
    if not is_instance_valid(_terrain) or not _terrain.is_tile_ready(job.tile):
        return false
    var tile_root := _terrain_root(job.tile)
    if tile_root == null or tile_root.is_queued_for_deletion() or tile_root.get_instance_id() != int(job.root_id):
        return false
    var land := tile_root.get_node_or_null("RegisteredLand") as MeshInstance3D
    return land != null and not land.is_queued_for_deletion() and land.get_instance_id() == int(job.land_id)

func _begin_job(tile: Vector2i) -> void:
    if not is_instance_valid(_terrain) or not _terrain.is_tile_ready(tile):
        return
    var tile_root := _terrain_root(tile)
    if tile_root == null:
        return
    var land := tile_root.get_node_or_null("RegisteredLand") as MeshInstance3D
    if land == null or land.mesh == null or land.mesh.get_surface_count() == 0:
        return
    var root_id := tile_root.get_instance_id()
    if int(_original_root_by_tile.get(tile, 0)) != root_id:
        _original_mesh_by_tile.erase(tile)
    var restore := not _segments_by_tile.has(tile)
    if restore and not _original_mesh_by_tile.has(tile):
        return
    if not _original_mesh_by_tile.has(tile):
        _original_mesh_by_tile[tile] = land.mesh
        _original_root_by_tile[tile] = root_id
    var source_mesh: ArrayMesh = _original_mesh_by_tile[tile]
    var key: String = _terrain._tile_key(tile.x, tile.y)
    var heights: PackedFloat32Array = _terrain._height_data.get(key, PackedFloat32Array())
    var coast: Dictionary = _terrain._coast_data.get(key, {})
    var mask: PackedByteArray = coast.get("mask", PackedByteArray())
    if not restore and (heights.size() != int(_terrain.resolution) * int(_terrain.resolution) or mask.is_empty()):
        return
    # Resource reads happen here, on the main thread. The worker receives only
    # independent value arrays and never dereferences a Node or Resource.
    var input := {"tile": tile, "source": source_mesh.surface_get_arrays(0),
        "segments": _segments_by_tile.get(tile, []).duplicate(true),
        "heights": heights, "mask": mask, "tile_size": float(_terrain.tile_size),
        "spacing": float(_terrain.spacing), "resolution": int(_terrain.resolution), "restore": restore}
    var cancellation := Cancellation.new()
    input["cancellation"] = cancellation
    var output: Dictionary = {}
    _job = {"tile": tile, "revision": int(_revisions.get(tile, 0)), "root_id": root_id,
        "land_id": land.get_instance_id(), "source_mesh": source_mesh, "output": output, "cancellation": cancellation}
    _task_id = WorkerThreadPool.add_task(_build_worker.bind(input, output), false, "Road corridor terrain")

static func _build_worker(input: Dictionary, output: Dictionary) -> void:
    var started := Time.get_ticks_usec()
    var result: Dictionary
    var plan := {"cells": {}, "structural_skips": 0}
    if not bool(input.restore):
        plan = refinement_plan(input.segments, input.tile, input.tile_size, input.spacing, input.resolution, input.mask, input.cancellation)
    var restore: bool = bool(input.restore) or plan.cells.is_empty()
    if restore:
        result = {"ok": true, "arrays": input.source}
    else:
        result = rebuild_value_arrays(input.source, input.heights, plan.cells, input.tile,
            input.tile_size, input.spacing, input.resolution, REFINE_STEP_M, input.cancellation)
    if input.cancellation.is_cancelled() or not bool(result.get("ok", false)):
        output["ok"] = false
        return
    var faces := PackedVector3Array()
    var vertices: PackedVector3Array = result.arrays[Mesh.ARRAY_VERTEX]
    var indices: PackedInt32Array = result.arrays[Mesh.ARRAY_INDEX]
    faces.resize(indices.size())
    for cursor in range(indices.size()):
        if cursor % 4096 == 0 and input.cancellation.is_cancelled():
            output["ok"] = false
            return
        faces[cursor] = vertices[indices[cursor]]
    result["faces"] = faces
    result["restore"] = restore
    result["refined_cells"] = plan.cells.size()
    result["structural_skips"] = plan.structural_skips
    result["worker_us"] = Time.get_ticks_usec() - started
    output.merge(result, true)

func _commit_job(job: Dictionary) -> bool:
    var tile_root := _terrain_root(job.tile)
    var land := tile_root.get_node_or_null("RegisteredLand") as MeshInstance3D
    # Reuse the existing collision body/shape node. The physics bubble owns its
    # layer, mask and disabled state; replacement must not silently reactivate it.
    var collider: CollisionShape3D
    for child in tile_root.get_children():
        if child is StaticBody3D:
            for shape_node in child.get_children():
                if shape_node is CollisionShape3D:
                    collider = shape_node
                    break
            if collider != null:
                break
    if collider == null:
        # An evicted/disabled physics residency without a body is not permission
        # to allocate a new active collider outside the terrain streamer's policy.
        return false
    collider.shape = job.shape
    land.mesh = job.mesh
    if bool(job.output.restore):
        for key in ["road_corridor_refined", "refined_cells", "removed_coarse_triangles", "micro_triangles", "structural_skips"]:
            land.remove_meta(key)
    else:
        land.set_meta("road_corridor_refined", true)
        land.set_meta("removed_coarse_triangles", int(job.output.removed_triangles))
        for key in ["refined_cells", "micro_triangles", "structural_skips"]:
            land.set_meta(key, int(job.output[key]))
    return true

static func refinement_plan(segments: Array, tile: Vector2i, tile_size: float, spacing: float,
        resolution: int, land_mask: PackedByteArray, cancellation: Cancellation = null) -> Dictionary:
    var cells: Dictionary = {}
    var structural_skips := 0
    if tile_size <= 0.0 or spacing <= 0.0 or resolution < 2 or not is_finite(tile_size) or not is_finite(spacing):
        return {"cells": cells, "structural_skips": structural_skips}
    if land_mask.size() != (resolution - 1) * (resolution - 1):
        return {"cells": cells, "structural_skips": structural_skips}
    var tile_origin := Vector2(float(tile.x) * tile_size, float(tile.y) * tile_size)
    for segment in segments:
        if cancellation != null and cancellation.is_cancelled():
            return {"cells": {}, "structural_skips": structural_skips}
        if not segment is Array or segment.size() < 12:
            continue
        var flags := int(segment[6])
        if flags & (FLAG_BRIDGE | FLAG_TUNNEL):
            structural_skips += 1
            continue
        var polygon = segment[11]
        if not polygon is Array or polygon.size() < 3:
            continue
        var width := float(segment[4])
        if not is_finite(width) or width < 1.0:
            continue
        var axis_start := Vector2(float(segment[0]), float(segment[1]))
        var axis_end := Vector2(float(segment[2]), float(segment[3]))
        if not is_finite(axis_start.x) or not is_finite(axis_start.y) or not is_finite(axis_end.x) or not is_finite(axis_end.y):
            continue
        var expand := width * 0.5 + clampf(width * 0.10, MIN_SHOULDER_M, MAX_SHOULDER_M) + 0.35 + EXCAVATION_MARGIN_M
        var min_x := INF
        var max_x := -INF
        var min_z := INF
        var max_z := -INF
        for raw_point in polygon:
            if not raw_point is Array or raw_point.size() < 3:
                continue
            var local_x := float(raw_point[0]) - tile_origin.x
            var local_z := float(raw_point[2]) - tile_origin.y
            if not is_finite(local_x) or not is_finite(local_z):
                continue
            min_x = minf(min_x, local_x)
            max_x = maxf(max_x, local_x)
            min_z = minf(min_z, local_z)
            max_z = maxf(max_z, local_z)
        if not is_finite(min_x):
            continue
        var x0 := clampi(int(floor((min_x - expand) / spacing)), 0, resolution - 2)
        var x1 := clampi(int(floor((max_x + expand) / spacing)), 0, resolution - 2)
        var z0 := clampi(int(floor((min_z - expand) / spacing)), 0, resolution - 2)
        var z1 := clampi(int(floor((max_z + expand) / spacing)), 0, resolution - 2)
        for z in range(z0, z1 + 1):
            if cancellation != null and cancellation.is_cancelled():
                return {"cells": {}, "structural_skips": structural_skips}
            for x in range(x0, x1 + 1):
                if land_mask[z * (resolution - 1) + x] != 1:
                    continue
                # Bounding boxes are only the broad phase. A long diagonal
                # crossing a tile must not micro-tessellate the entire tile.
                var cell_rect := Rect2(tile_origin + Vector2(float(x), float(z)) * spacing, Vector2.ONE * spacing)
                if not _corridor_touches_cell(axis_start, axis_end, expand, cell_rect):
                    continue
                var cell_key := "%d:%d" % [x, z]
                if not cells.has(cell_key):
                    cells[cell_key] = {"cell": Vector2i(x, z), "segments": []}
                cells[cell_key].segments.append(segment)
    return {"cells": cells, "structural_skips": structural_skips}

static func _corridor_touches_cell(a: Vector2, b: Vector2, radius: float, cell: Rect2) -> bool:
    var radius_squared := radius * radius + 0.000001
    # Endpoint-to-rectangle distances cover short roads ending beside a cell.
    for point in [a, b]:
        var nearest := Vector2(clampf(point.x, cell.position.x, cell.end.x), clampf(point.y, cell.position.y, cell.end.y))
        if point.distance_squared_to(nearest) <= radius_squared:
            return true
    var corners := [cell.position, Vector2(cell.end.x, cell.position.y), cell.end, Vector2(cell.position.x, cell.end.y)]
    for index in range(4):
        var corner: Vector2 = corners[index]
        if corner.distance_squared_to(Geometry2D.get_closest_point_to_segment(corner, a, b)) <= radius_squared:
            return true
        if Geometry2D.segment_intersects_segment(a, b, corner, corners[(index + 1) % 4]) != null:
            return true
    return false

func rebuild_land_arrays(source_mesh: ArrayMesh, heights: PackedFloat32Array, cells: Dictionary,
        tile: Vector2i, tile_size: float, spacing: float, resolution: int,
        refine_step_m: float = REFINE_STEP_M) -> Dictionary:
    if source_mesh == null or source_mesh.get_surface_count() == 0:
        return {"ok": false}
    return rebuild_value_arrays(source_mesh.surface_get_arrays(0), heights, cells, tile,
        tile_size, spacing, resolution, refine_step_m)

static func rebuild_value_arrays(source: Array, heights: PackedFloat32Array, cells: Dictionary,
        tile: Vector2i, tile_size: float, spacing: float, resolution: int,
        refine_step_m: float = REFINE_STEP_M, cancellation: Cancellation = null) -> Dictionary:
    if cells.is_empty() or heights.size() != resolution * resolution or refine_step_m <= 0.0 or not is_finite(refine_step_m):
        return {"ok": false}
    var vertices: PackedVector3Array = source[Mesh.ARRAY_VERTEX].duplicate()
    var normals: PackedVector3Array = source[Mesh.ARRAY_NORMAL].duplicate()
    var colors: PackedColorArray = source[Mesh.ARRAY_COLOR].duplicate()
    var old_indices: PackedInt32Array = source[Mesh.ARRAY_INDEX]
    if vertices.is_empty() or old_indices.is_empty():
        return {"ok": false}
    var indices := PackedInt32Array()
    var removed_triangles := 0
    for cursor in range(0, old_indices.size(), 3):
        if cursor + 2 >= old_indices.size():
            break
        var ia := int(old_indices[cursor])
        var ib := int(old_indices[cursor + 1])
        var ic := int(old_indices[cursor + 2])
        var center := (vertices[ia] + vertices[ib] + vertices[ic]) / 3.0
        var cx := clampi(int(floor(center.x / spacing)), 0, resolution - 2)
        var cz := clampi(int(floor(center.z / spacing)), 0, resolution - 2)
        if cells.has("%d:%d" % [cx, cz]):
            removed_triangles += 1
            continue
        indices.append_array(PackedInt32Array([ia, ib, ic]))

    var tile_origin := Vector2(float(tile.x) * tile_size, float(tile.y) * tile_size)
    var micro_triangles := 0
    var ordered_keys: Array = cells.keys()
    ordered_keys.sort()
    for cell_key in ordered_keys:
        if cancellation != null and cancellation.is_cancelled():
            return {"ok": false}
        var record: Dictionary = cells[cell_key]
        var cell: Vector2i = record.cell
        micro_triangles += _append_refined_cell(vertices, normals, colors, indices, heights,
            cell, record.segments, tile_origin, spacing, resolution, refine_step_m)
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = normals
    arrays[Mesh.ARRAY_COLOR] = colors
    arrays[Mesh.ARRAY_INDEX] = indices
    return {"ok": true, "arrays": arrays, "removed_triangles": removed_triangles,
        "micro_triangles": micro_triangles}

static func _append_refined_cell(vertices: PackedVector3Array, normals: PackedVector3Array,
        colors: PackedColorArray, indices: PackedInt32Array, heights: PackedFloat32Array,
        cell: Vector2i, segments: Array, tile_origin: Vector2, spacing: float,
        resolution: int, refine_step_m: float) -> int:
    var subdivisions := maxi(1, int(ceil(spacing / refine_step_m)))
    var step := spacing / float(subdivisions)
    var side := subdivisions + 1
    var sampled := PackedFloat32Array()
    sampled.resize(side * side)
    for iz in range(side):
        for ix in range(side):
            var u := float(ix) / float(subdivisions)
            var v := float(iz) / float(subdivisions)
            var local_x := (float(cell.x) + u) * spacing
            var local_z := (float(cell.y) + v) * spacing
            var raw := _cell_height(heights, cell, u, v, resolution)
            sampled[iz * side + ix] = carved_height(raw, tile_origin.x + local_x,
                tile_origin.y + local_z, segments)
    var base := vertices.size()
    for iz in range(side):
        for ix in range(side):
            var local_x := float(cell.x) * spacing + float(ix) * step
            var local_z := float(cell.y) * spacing + float(iz) * step
            var y := float(sampled[iz * side + ix])
            var xl := maxi(ix - 1, 0)
            var xr := mini(ix + 1, side - 1)
            var zu := maxi(iz - 1, 0)
            var zd := mini(iz + 1, side - 1)
            var dx_span := maxf(float(xr - xl) * step, 0.001)
            var dz_span := maxf(float(zd - zu) * step, 0.001)
            var dx := (float(sampled[iz * side + xl]) - float(sampled[iz * side + xr])) / dx_span
            var dz := (float(sampled[zu * side + ix]) - float(sampled[zd * side + ix])) / dz_span
            vertices.append(Vector3(local_x, y, local_z))
            normals.append(Vector3(dx, 1.0, dz).normalized())
            colors.append(_height_color(y, Vector2(dx, dz).length()))
    # The grid alone can interpolate a high bank across a narrow road even
    # when all samples on its axis are below the deck. Insert the actual ribbon
    # edges into intersecting micro-triangles; every triangle beneath a deck
    # then lies on/below its longitudinal plane instead of spanning its bank.
    var decks := _local_decks(segments, tile_origin)
    var triangle_count := 0
    for iz in range(subdivisions):
        for ix in range(subdivisions):
            var a := base + iz * side + ix
            var b := a + 1
            var c := a + side
            var d := c + 1
            for triangle in [[a, b, c], [b, d, c]]:
                var points: Array = []
                for index in triangle:
                    var vertex: Vector3 = vertices[index]
                    points.append(Vector2(vertex.x, vertex.z))
                var pieces: Array = [points]
                for deck in decks:
                    var next_pieces: Array = []
                    for piece in pieces:
                        next_pieces.append_array(_partition_at_ribbon(piece, deck.polygon))
                    pieces = next_pieces
                if pieces.size() == 1 and pieces[0] == points:
                    indices.append_array(PackedInt32Array(triangle))
                    triangle_count += 1
                    continue
                for piece in pieces:
                    for index in range(1, piece.size() - 1):
                        var face := PackedVector3Array()
                        for point in [piece[0], piece[index], piece[index + 1]]:
                            var u := (float(point.x) - float(cell.x) * spacing) / spacing
                            var v := (float(point.y) - float(cell.y) * spacing) / spacing
                            var raw := _cell_height(heights, cell, u, v, resolution)
                            var y := carved_height(raw, tile_origin.x + point.x, tile_origin.y + point.y, segments)
                            for deck in decks:
                                if _in_convex_polygon(point, deck.polygon):
                                    var t := clampf((point - deck.a).dot(deck.axis) / deck.length_sq, 0.0, 1.0)
                                    y = minf(y, lerpf(deck.y0, deck.y1, t) - DECK_CLEARANCE_M)
                            face.append(Vector3(point.x, y, point.y))
                        var normal := (face[2] - face[0]).cross(face[1] - face[0]).normalized()
                        if normal.length_squared() < 0.5:
                            continue
                        for vertex in face:
                            indices.append(vertices.size())
                            vertices.append(vertex)
                            normals.append(normal)
                            colors.append(_height_color(vertex.y, Vector2(normal.x, normal.z).length() / maxf(normal.y, 0.001)))
                        triangle_count += 1
    return triangle_count

static func _local_decks(segments: Array, tile_origin: Vector2) -> Array:
    var decks: Array = []
    for segment in segments:
        if not segment is Array or segment.size() < 12 or int(segment[6]) & (FLAG_BRIDGE | FLAG_TUNNEL):
            continue
        if not segment[11] is Array:
            continue
        var polygon: Array = []
        for raw in segment[11]:
            if not raw is Array or raw.size() < 3:
                polygon.clear()
                break
            var point := Vector2(float(raw[0]), float(raw[2])) - tile_origin
            if not is_finite(point.x) or not is_finite(point.y):
                polygon.clear()
                break
            if polygon.is_empty() or point.distance_squared_to(polygon[-1]) > 0.00000001:
                polygon.append(point)
        if polygon.size() > 2 and polygon[0].distance_squared_to(polygon[-1]) < 0.00000001:
            polygon.pop_back()
        if polygon.size() < 3:
            continue
        var a := Vector2(float(segment[0]), float(segment[1])) - tile_origin
        var axis := Vector2(float(segment[2]), float(segment[3])) - tile_origin - a
        if axis.length_squared() < 0.0025 or not is_finite(float(segment[9])) or not is_finite(float(segment[10])):
            continue
        # Compiler ribbons are convex quads. Triangulating also supports a
        # clipped/concave ribbon without excavating its convex hull.
        var polygons: Array = []
        var orientation := 1.0 if _polygon_area(polygon) >= 0.0 else -1.0
        var convex := true
        for index in range(polygon.size()):
            var before: Vector2 = polygon[index]
            var current: Vector2 = polygon[(index + 1) % polygon.size()]
            var after: Vector2 = polygon[(index + 2) % polygon.size()]
            if (current - before).cross(after - current) * orientation < -0.00001:
                convex = false
                break
        if convex:
            polygons.append(polygon)
        else:
            var triangulation := Geometry2D.triangulate_polygon(PackedVector2Array(polygon))
            for cursor in range(0, triangulation.size(), 3):
                polygons.append([polygon[triangulation[cursor]], polygon[triangulation[cursor + 1]], polygon[triangulation[cursor + 2]]])
        for convex_polygon in polygons:
            decks.append({"polygon": convex_polygon, "a": a, "axis": axis,
                "length_sq": axis.length_squared(), "y0": float(segment[9]), "y1": float(segment[10])})
    return decks

static func _polygon_area(points: Array) -> float:
    var area := 0.0
    for index in range(points.size()):
        area += Vector2(points[index]).cross(Vector2(points[(index + 1) % points.size()]))
    return area * 0.5

static func _in_convex_polygon(point: Vector2, polygon: Array) -> bool:
    var orientation := 1.0 if _polygon_area(polygon) >= 0.0 else -1.0
    for index in range(polygon.size()):
        var a: Vector2 = polygon[index]
        var b: Vector2 = polygon[(index + 1) % polygon.size()]
        if (b - a).cross(point - a) * orientation < -0.00001:
            return false
    return true

static func _clip_half_plane(points: Array, a: Vector2, b: Vector2, sign_value: float) -> Array:
    var result: Array = []
    if points.is_empty():
        return result
    var previous: Vector2 = points[-1]
    var previous_distance := (b - a).cross(previous - a) * sign_value
    for current: Vector2 in points:
        var distance := (b - a).cross(current - a) * sign_value
        if (distance >= 0.0) != (previous_distance >= 0.0):
            var intersection := previous.lerp(current, previous_distance / (previous_distance - distance))
            if result.is_empty() or intersection.distance_squared_to(result[-1]) > 0.00000001:
                result.append(intersection)
        if distance >= 0.0 and (result.is_empty() or current.distance_squared_to(result[-1]) > 0.00000001):
            result.append(current)
        previous = current
        previous_distance = distance
    if result.size() > 2 and result[0].distance_squared_to(result[-1]) < 0.00000001:
        result.pop_back()
    return result if result.size() >= 3 and absf(_polygon_area(result)) > 0.000001 else []

static func _partition_at_ribbon(points: Array, polygon: Array) -> Array:
    var touches := false
    for point in points:
        if _in_convex_polygon(point, polygon):
            touches = true
            break
    if not touches:
        for point in polygon:
            if _in_convex_polygon(point, points):
                touches = true
                break
    if not touches:
        for index in range(points.size()):
            for edge in range(polygon.size()):
                if Geometry2D.segment_intersects_segment(points[index], points[(index + 1) % points.size()],
                        polygon[edge], polygon[(edge + 1) % polygon.size()]) != null:
                    touches = true
                    break
            if touches:
                break
    if not touches:
        return [points]
    # Include zero-area contacts: an adjoining triangle must receive the same
    # boundary vertex, otherwise its unsplit edge can overhang the deck edge.
    var pieces: Array = [points]
    for index in range(polygon.size()):
        var next_pieces: Array = []
        for piece in pieces:
            for side_sign in [-1.0, 1.0]:
                var clipped := _clip_half_plane(piece, polygon[index], polygon[(index + 1) % polygon.size()], side_sign)
                if not clipped.is_empty():
                    next_pieces.append(clipped)
        pieces = next_pieces
    return pieces

static func _cell_height(heights: PackedFloat32Array, cell: Vector2i, u: float, v: float,
        resolution: int) -> float:
    var a := float(heights[cell.y * resolution + cell.x])
    var b := float(heights[cell.y * resolution + cell.x + 1])
    var c := float(heights[(cell.y + 1) * resolution + cell.x])
    var d := float(heights[(cell.y + 1) * resolution + cell.x + 1])
    if u + v <= 1.0:
        return a + (b - a) * u + (c - a) * v
    return d + (c - d) * (1.0 - u) + (b - d) * (1.0 - v)

static func carved_height(raw_height: float, world_x: float, world_z: float, segments: Array) -> float:
    if not is_finite(raw_height) or not is_finite(world_x) or not is_finite(world_z):
        return raw_height
    var result := raw_height
    var point := Vector2(world_x, world_z)
    for segment in segments:
        if not segment is Array or segment.size() < 11:
            continue
        var flags := int(segment[6])
        if flags & (FLAG_BRIDGE | FLAG_TUNNEL):
            continue
        var a := Vector2(float(segment[0]), float(segment[1]))
        var b := Vector2(float(segment[2]), float(segment[3]))
        var delta := b - a
        var length_sq := delta.length_squared()
        var width := float(segment[4])
        if length_sq < 0.0025 or width < 1.0:
            continue
        var t := clampf((point - a).dot(delta) / length_sq, 0.0, 1.0)
        var nearest := a + delta * t
        var distance := point.distance_to(nearest)
        var shoulder := clampf(width * 0.10, MIN_SHOULDER_M, MAX_SHOULDER_M)
        var inner := width * 0.5 + shoulder + 0.35
        var outer := inner + EXCAVATION_MARGIN_M
        if distance >= outer:
            continue
        var deck_y := lerpf(float(segment[9]), float(segment[10]), t)
        var deck_floor := deck_y - DECK_CLEARANCE_M
        if result <= deck_floor:
            continue
        var allowed := deck_floor
        if distance > inner:
            var blend := clampf((distance - inner) / maxf(outer - inner, 0.001), 0.0, 1.0)
            blend = blend * blend * (3.0 - 2.0 * blend)
            allowed = lerpf(deck_floor, raw_height, blend)
        result = minf(result, allowed)
    return result

static func _height_color(height: float, slope: float) -> Color:
    if height < 2.0:
        return Color(0.38, 0.43, 0.25)
    var low := Color(0.24, 0.38, 0.14)
    var high := Color(0.12, 0.26, 0.18)
    var color := low.lerp(high, clampf(height / 1800.0, 0.0, 1.0))
    return color.lerp(Color(0.48, 0.43, 0.34), clampf((slope - 0.45) * 0.8, 0.0, 0.65))
