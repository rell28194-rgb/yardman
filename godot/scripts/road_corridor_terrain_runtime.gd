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

func _terrain_root(tile: Vector2i) -> Node3D:
    if _terrain == null:
        return null
    return _terrain.get_node_or_null("TerrainTile_%d_%d" % [tile.x, tile.y]) as Node3D

func _try_refine(tile: Vector2i) -> void:
    if _terrain == null or not _terrain.is_tile_ready(tile) or not _segments_by_tile.has(tile):
        return
    var tile_root := _terrain_root(tile)
    if tile_root == null:
        return
    var land := tile_root.get_node_or_null("RegisteredLand") as MeshInstance3D
    if land == null or land.mesh == null or land.mesh.get_surface_count() == 0:
        return
    var key: String = _terrain._tile_key(tile.x, tile.y)
    var heights: PackedFloat32Array = _terrain._height_data.get(key, PackedFloat32Array())
    var coast: Dictionary = _terrain._coast_data.get(key, {})
    var mask: PackedByteArray = coast.get("mask", PackedByteArray())
    if heights.size() != int(_terrain.resolution) * int(_terrain.resolution) or mask.is_empty():
        return

    if not _original_mesh_by_tile.has(tile):
        _original_mesh_by_tile[tile] = land.mesh
    var source_mesh: ArrayMesh = _original_mesh_by_tile[tile]
    var plan := refinement_plan(_segments_by_tile[tile], tile, float(_terrain.tile_size),
        float(_terrain.spacing), int(_terrain.resolution), mask)
    var cells: Dictionary = plan.get("cells", {})
    if cells.is_empty():
        _restore_tile(tile)
        return
    var result := rebuild_land_arrays(source_mesh, heights, cells, tile, float(_terrain.tile_size),
        float(_terrain.spacing), int(_terrain.resolution), REFINE_STEP_M)
    if not bool(result.get("ok", false)):
        push_warning("Road corridor terrain refinement failed for %s" % str(tile))
        return
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, result.arrays)
    mesh.surface_set_material(0, source_mesh.surface_get_material(0))
    land.mesh = mesh
    land.set_meta("road_corridor_refined", true)
    land.set_meta("refined_cells", cells.size())
    land.set_meta("removed_coarse_triangles", int(result.removed_triangles))
    land.set_meta("micro_triangles", int(result.micro_triangles))
    land.set_meta("structural_skips", int(plan.get("structural_skips", 0)))
    _replace_collision(tile_root, result.arrays)

func _restore_tile(tile: Vector2i) -> void:
    if not _original_mesh_by_tile.has(tile):
        return
    var tile_root := _terrain_root(tile)
    if tile_root == null:
        return
    var land := tile_root.get_node_or_null("RegisteredLand") as MeshInstance3D
    if land == null:
        return
    var source_mesh: ArrayMesh = _original_mesh_by_tile[tile]
    land.mesh = source_mesh
    land.remove_meta("road_corridor_refined")
    land.remove_meta("refined_cells")
    land.remove_meta("removed_coarse_triangles")
    land.remove_meta("micro_triangles")
    land.remove_meta("structural_skips")
    _replace_collision(tile_root, source_mesh.surface_get_arrays(0))

func refinement_plan(segments: Array, tile: Vector2i, tile_size: float, spacing: float,
        resolution: int, land_mask: PackedByteArray) -> Dictionary:
    var cells: Dictionary = {}
    var structural_skips := 0
    if tile_size <= 0.0 or spacing <= 0.0 or resolution < 2 or not is_finite(tile_size) or not is_finite(spacing):
        return {"cells": cells, "structural_skips": structural_skips}
    if land_mask.size() != (resolution - 1) * (resolution - 1):
        return {"cells": cells, "structural_skips": structural_skips}
    var tile_origin := Vector2(float(tile.x) * tile_size, float(tile.y) * tile_size)
    for segment in segments:
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
        var expand := width * 0.5 + MAX_SHOULDER_M + EXCAVATION_MARGIN_M
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
            for x in range(x0, x1 + 1):
                if land_mask[z * (resolution - 1) + x] != 1:
                    continue
                var cell_key := "%d:%d" % [x, z]
                if not cells.has(cell_key):
                    cells[cell_key] = {"cell": Vector2i(x, z), "segments": []}
                cells[cell_key].segments.append(segment)
    return {"cells": cells, "structural_skips": structural_skips}

func rebuild_land_arrays(source_mesh: ArrayMesh, heights: PackedFloat32Array, cells: Dictionary,
        tile: Vector2i, tile_size: float, spacing: float, resolution: int,
        refine_step_m: float = REFINE_STEP_M) -> Dictionary:
    if source_mesh == null or source_mesh.get_surface_count() == 0 or cells.is_empty():
        return {"ok": false}
    if heights.size() != resolution * resolution or refine_step_m <= 0.0 or not is_finite(refine_step_m):
        return {"ok": false}
    var source: Array = source_mesh.surface_get_arrays(0)
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

func _append_refined_cell(vertices: PackedVector3Array, normals: PackedVector3Array,
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
    for iz in range(subdivisions):
        for ix in range(subdivisions):
            var a := base + iz * side + ix
            var b := a + 1
            var c := a + side
            var d := c + 1
            indices.append_array(PackedInt32Array([a, b, c, b, d, c]))
    return subdivisions * subdivisions * 2

func _cell_height(heights: PackedFloat32Array, cell: Vector2i, u: float, v: float,
        resolution: int) -> float:
    var a := float(heights[cell.y * resolution + cell.x])
    var b := float(heights[cell.y * resolution + cell.x + 1])
    var c := float(heights[(cell.y + 1) * resolution + cell.x])
    var d := float(heights[(cell.y + 1) * resolution + cell.x + 1])
    if u + v <= 1.0:
        return a + (b - a) * u + (c - a) * v
    return d + (c - d) * (1.0 - u) + (b - d) * (1.0 - v)

func carved_height(raw_height: float, world_x: float, world_z: float, segments: Array) -> float:
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

func _replace_collision(tile_root: Node3D, arrays: Array) -> void:
    var old_body: StaticBody3D
    for child in tile_root.get_children():
        if child is StaticBody3D:
            old_body = child as StaticBody3D
            break
    if old_body != null:
        tile_root.remove_child(old_body)
        old_body.queue_free()
    var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
    var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
    if vertices.is_empty() or indices.is_empty():
        return
    var faces := PackedVector3Array()
    for index in indices:
        faces.append(vertices[int(index)])
    var shape := ConcavePolygonShape3D.new()
    shape.backface_collision = true
    shape.set_faces(faces)
    var collider := CollisionShape3D.new()
    collider.shape = shape
    var body := StaticBody3D.new()
    body.name = "RoadAwareTerrainCollision"
    body.collision_layer = 1
    body.collision_mask = 0
    body.add_child(collider)
    tile_root.add_child(body)

func _height_color(height: float, slope: float) -> Color:
    if height < 2.0:
        return Color(0.38, 0.43, 0.25)
    var low := Color(0.24, 0.38, 0.14)
    var high := Color(0.12, 0.26, 0.18)
    var color := low.lerp(high, clampf(height / 1800.0, 0.0, 1.0))
    return color.lerp(Color(0.48, 0.43, 0.34), clampf((slope - 0.45) * 0.8, 0.0, 0.65))
