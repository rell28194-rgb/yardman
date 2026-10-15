extends Node

# Visualizes only registered Jamaica drainage evidence compiled from OSM.
# Mapped ditch/drain centerlines get terrain-following channel ribbons;
# explicit culverts get portal frames only at true source-way endpoints. This
# layer never invents drainage crossings or alters road/terrain authority.
const MAX_SPAN_M := 5.0
const MAX_ITEMS_PER_TILE := 768
const DEFAULT_DITCH_WIDTH_M := 0.80
const DEFAULT_DRAIN_WIDTH_M := 0.60
const DEFAULT_CULVERT_WIDTH_M := 0.90
const MIN_WIDTH_M := 0.25
const MAX_WIDTH_M := 5.0
const CHANNEL_SURFACE_LIFT_M := 0.018
const CHANNEL_LIP_LIFT_M := 0.032
const MIN_LIP_WIDTH_M := 0.06
const MAX_LIP_WIDTH_M := 0.18
const VISIBILITY_RANGE_M := 900.0

var _terrain: Node
var _connected := false
var _material: StandardMaterial3D
var _record_cache: Dictionary = {}

func _ready() -> void:
    set_process(true)

func _process(_delta: float) -> void:
    if _connected:
        set_process(false)
        return
    var scene := get_tree().current_scene
    if scene == null:
        return
    _terrain = scene.get_node_or_null("JamaicaTerrainStreamer")
    if _terrain == null:
        return
    _terrain.tile_ready.connect(_on_terrain_tile)
    _terrain.tile_removed.connect(_on_terrain_tile_removed)
    _connected = true
    set_process(false)

func _on_terrain_tile(tile: Vector2i) -> void:
    var root := _terrain.get_node_or_null("TerrainTile_%d_%d" % [tile.x, tile.y]) as Node3D
    if root != null:
        _decorate(tile, root)

func _on_terrain_tile_removed(tile: Vector2i) -> void:
    var root := _terrain.get_node_or_null("TerrainTile_%d_%d" % [tile.x, tile.y]) as Node3D
    if root == null:
        return
    var existing := root.get_node_or_null("RoadDrainageProxy")
    if existing != null:
        root.remove_child(existing)
        existing.queue_free()

func _decorate(tile: Vector2i, tile_root: Node3D) -> void:
    var existing := tile_root.get_node_or_null("RoadDrainageProxy")
    if existing != null:
        tile_root.remove_child(existing)
        existing.queue_free()
    var records := records_for_tile(tile)
    if records.is_empty():
        return
    var plan := placement_plan(records, tile, float(_terrain.tile_size), MAX_SPAN_M)
    if plan.is_empty():
        return
    var origin := Vector2(float(tile.x) * float(_terrain.tile_size), float(tile.y) * float(_terrain.tile_size))
    var geometry := build_geometry(plan, origin, _terrain.height_at)
    var vertices: PackedVector3Array = geometry.vertices
    if vertices.is_empty():
        return
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = geometry.normals
    arrays[Mesh.ARRAY_COLOR] = geometry.colors
    arrays[Mesh.ARRAY_INDEX] = geometry.indices
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    mesh.surface_set_material(0, _drainage_material())

    var proxy := Node3D.new()
    proxy.name = "RoadDrainageProxy"
    proxy.set_meta("placement_source", "explicit Jamaica OSM ditch/drain/culvert evidence only")
    proxy.set_meta("channel_spans", int(geometry.channel_spans))
    proxy.set_meta("culvert_portals", int(geometry.culvert_portals))
    var instance := MeshInstance3D.new()
    instance.name = "RoadDrainageGeometry"
    instance.mesh = mesh
    instance.visibility_range_end = VISIBILITY_RANGE_M
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    proxy.add_child(instance)
    tile_root.add_child(proxy)

func records_for_tile(tile: Vector2i) -> Array:
    var cache_key := "%d:%d" % [tile.x, tile.y]
    if _record_cache.has(cache_key):
        return _record_cache[cache_key]
    var path := "res://data/roads/drainage/tile_%d_%d.json" % [tile.x, tile.y]
    if not FileAccess.file_exists(path):
        _record_cache[cache_key] = []
        return []
    var payload = JSON.parse_string(FileAccess.get_file_as_string(path))
    if not payload is Dictionary or not payload.get("drainage", null) is Array:
        push_warning("Invalid Yardman drainage tile: " + path)
        _record_cache[cache_key] = []
        return []
    var records: Array = payload.drainage
    _record_cache[cache_key] = records
    return records

func has_mapped_channel_near(world_point: Vector2, radius_m: float, tile_size_m: float = 4096.0) -> bool:
    if radius_m < 0.0 or tile_size_m <= 0.0 or not is_finite(radius_m) or not is_finite(tile_size_m):
        return false
    if not is_finite(world_point.x) or not is_finite(world_point.y):
        return false
    var min_tx := int(floor((world_point.x - radius_m) / tile_size_m))
    var max_tx := int(floor((world_point.x + radius_m) / tile_size_m))
    var min_tz := int(floor((world_point.y - radius_m) / tile_size_m))
    var max_tz := int(floor((world_point.y + radius_m) / tile_size_m))
    for tz in range(min_tz, max_tz + 1):
        for tx in range(min_tx, max_tx + 1):
            if records_have_channel_near(records_for_tile(Vector2i(tx, tz)), world_point, radius_m):
                return true
    return false

func records_have_channel_near(records: Array, world_point: Vector2, radius_m: float) -> bool:
    if radius_m < 0.0 or not is_finite(radius_m) or not is_finite(world_point.x) or not is_finite(world_point.y):
        return false
    for record in records:
        if not record is Dictionary or str(record.get("kind", "")) not in ["ditch", "drain"]:
            continue
        var start_raw = record.get("start", [])
        var end_raw = record.get("end", [])
        if not start_raw is Array or not end_raw is Array or start_raw.size() < 2 or end_raw.size() < 2:
            continue
        var a := Vector2(float(start_raw[0]), float(start_raw[1]))
        var b := Vector2(float(end_raw[0]), float(end_raw[1]))
        if not is_finite(a.x) or not is_finite(a.y) or not is_finite(b.x) or not is_finite(b.y):
            continue
        var width := float(record.get("width_m", _default_width(str(record.get("kind", "ditch")))))
        if not is_finite(width):
            width = _default_width(str(record.get("kind", "ditch")))
        width = clampf(width, MIN_WIDTH_M, MAX_WIDTH_M)
        if _distance_to_segment(world_point, a, b) <= radius_m + width * 0.5:
            return true
    return false

func _distance_to_segment(point: Vector2, a: Vector2, b: Vector2) -> float:
    var axis := b - a
    var length_squared := axis.length_squared()
    if length_squared < 0.000001:
        return point.distance_to(a)
    var t := clampf((point - a).dot(axis) / length_squared, 0.0, 1.0)
    return point.distance_to(a + axis * t)

func placement_plan(records: Array, tile: Vector2i, tile_size: float,
        max_span_m: float = MAX_SPAN_M) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    if tile_size <= 0.0 or max_span_m <= 0.0 or not is_finite(tile_size) or not is_finite(max_span_m):
        return result
    for record in records:
        if result.size() >= MAX_ITEMS_PER_TILE:
            break
        if not record is Dictionary:
            continue
        var kind := str(record.get("kind", ""))
        if kind not in ["ditch", "drain", "culvert"]:
            continue
        var start_raw = record.get("start", [])
        var end_raw = record.get("end", [])
        if not start_raw is Array or not end_raw is Array or start_raw.size() < 2 or end_raw.size() < 2:
            continue
        var a := Vector2(float(start_raw[0]), float(start_raw[1]))
        var b := Vector2(float(end_raw[0]), float(end_raw[1]))
        if not is_finite(a.x) or not is_finite(a.y) or not is_finite(b.x) or not is_finite(b.y):
            continue
        var delta := b - a
        var length := delta.length()
        if length < 0.05:
            continue
        var midpoint := (a + b) * 0.5
        if int(floor(midpoint.x / tile_size)) != tile.x or int(floor(midpoint.y / tile_size)) != tile.y:
            continue
        var source_way := str(record.get("source_way", ""))
        if source_way.is_empty():
            continue
        var width := float(record.get("width_m", _default_width(kind)))
        if not is_finite(width):
            width = _default_width(kind)
        width = clampf(width, MIN_WIDTH_M, MAX_WIDTH_M)
        if kind in ["ditch", "drain"]:
            var spans := maxi(1, int(ceil(length / max_span_m)))
            for index in range(spans):
                if result.size() >= MAX_ITEMS_PER_TILE:
                    break
                var p0 := a.lerp(b, float(index) / float(spans))
                var p1 := a.lerp(b, float(index + 1) / float(spans))
                result.append({
                    "kind": "channel",
                    "channel_type": kind,
                    "source_way": source_way,
                    "world_ax": p0.x, "world_az": p0.y,
                    "world_bx": p1.x, "world_bz": p1.y,
                    "width_m": width,
                    "width_source": "OSM" if record.has("width_m") else "visual_fallback",
                })
            continue
        var axis := delta / length
        if bool(record.get("portal_start", false)) and result.size() < MAX_ITEMS_PER_TILE:
            result.append(_portal_item(source_way, a, -axis, width, record))
        if bool(record.get("portal_end", false)) and result.size() < MAX_ITEMS_PER_TILE:
            result.append(_portal_item(source_way, b, axis, width, record))
    return result

func _portal_item(source_way: String, point: Vector2, outward: Vector2, width: float,
        record: Dictionary) -> Dictionary:
    return {
        "kind": "culvert_portal",
        "source_way": source_way,
        "world_x": point.x,
        "world_z": point.y,
        "out_x": outward.x,
        "out_z": outward.y,
        "width_m": width,
        "width_source": "OSM" if record.has("width_m") else "visual_fallback",
        "material": str(record.get("material", "unspecified")),
    }

func build_geometry(plan: Array[Dictionary], tile_origin: Vector2, height_sampler: Callable) -> Dictionary:
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var colors := PackedColorArray()
    var indices := PackedInt32Array()
    var channel_spans := 0
    var culvert_portals := 0
    if not height_sampler.is_valid():
        return {"vertices": vertices, "normals": normals, "colors": colors, "indices": indices,
            "channel_spans": 0, "culvert_portals": 0}
    for item: Dictionary in plan:
        var kind := str(item.get("kind", ""))
        if kind == "channel":
            var a2 := Vector2(float(item.world_ax), float(item.world_az))
            var b2 := Vector2(float(item.world_bx), float(item.world_bz))
            var axis := b2 - a2
            var length := axis.length()
            if length < 0.05:
                continue
            var width := clampf(float(item.get("width_m", DEFAULT_DITCH_WIDTH_M)), MIN_WIDTH_M, MAX_WIDTH_M)
            var lateral := Vector2(-axis.y, axis.x).normalized()
            var half_width := width * 0.5
            var lip_width := clampf(width * 0.12, MIN_LIP_WIDTH_M, MAX_LIP_WIDTH_M)
            var inner_side := lateral * half_width
            var outer_side := lateral * (half_width + lip_width)
            var a_left_2 := a2 + inner_side
            var a_right_2 := a2 - inner_side
            var b_left_2 := b2 + inner_side
            var b_right_2 := b2 - inner_side
            var a_outer_left_2 := a2 + outer_side
            var a_outer_right_2 := a2 - outer_side
            var b_outer_left_2 := b2 + outer_side
            var b_outer_right_2 := b2 - outer_side
            var heights := PackedFloat32Array([
                float(height_sampler.call(a_left_2.x, a_left_2.y)),
                float(height_sampler.call(a_right_2.x, a_right_2.y)),
                float(height_sampler.call(b_left_2.x, b_left_2.y)),
                float(height_sampler.call(b_right_2.x, b_right_2.y)),
                float(height_sampler.call(a_outer_left_2.x, a_outer_left_2.y)),
                float(height_sampler.call(a_outer_right_2.x, a_outer_right_2.y)),
                float(height_sampler.call(b_outer_left_2.x, b_outer_left_2.y)),
                float(height_sampler.call(b_outer_right_2.x, b_outer_right_2.y)),
            ])
            var valid := true
            for height in heights:
                if not is_finite(height):
                    valid = false
                    break
            if not valid:
                continue
            var a_left := Vector3(a_left_2.x - tile_origin.x, heights[0] + CHANNEL_SURFACE_LIFT_M, a_left_2.y - tile_origin.y)
            var a_right := Vector3(a_right_2.x - tile_origin.x, heights[1] + CHANNEL_SURFACE_LIFT_M, a_right_2.y - tile_origin.y)
            var b_left := Vector3(b_left_2.x - tile_origin.x, heights[2] + CHANNEL_SURFACE_LIFT_M, b_left_2.y - tile_origin.y)
            var b_right := Vector3(b_right_2.x - tile_origin.x, heights[3] + CHANNEL_SURFACE_LIFT_M, b_right_2.y - tile_origin.y)
            var a_outer_left := Vector3(a_outer_left_2.x - tile_origin.x, heights[4] + CHANNEL_LIP_LIFT_M, a_outer_left_2.y - tile_origin.y)
            var a_outer_right := Vector3(a_outer_right_2.x - tile_origin.x, heights[5] + CHANNEL_LIP_LIFT_M, a_outer_right_2.y - tile_origin.y)
            var b_outer_left := Vector3(b_outer_left_2.x - tile_origin.x, heights[6] + CHANNEL_LIP_LIFT_M, b_outer_left_2.y - tile_origin.y)
            var b_outer_right := Vector3(b_outer_right_2.x - tile_origin.x, heights[7] + CHANNEL_LIP_LIFT_M, b_outer_right_2.y - tile_origin.y)
            var channel_type := str(item.get("channel_type", "ditch"))
            var channel_color := Color(0.16, 0.19, 0.14, 1.0) if channel_type == "ditch" else Color(0.17, 0.18, 0.17, 1.0)
            var lip_color := Color(0.27, 0.30, 0.20, 1.0) if channel_type == "ditch" else Color(0.39, 0.39, 0.37, 1.0)
            _append_quad(a_left, b_left, b_right, a_right, channel_color, vertices, normals, colors, indices)
            _append_quad(a_outer_left, b_outer_left, b_left, a_left, lip_color, vertices, normals, colors, indices)
            _append_quad(a_right, b_right, b_outer_right, a_outer_right, lip_color, vertices, normals, colors, indices)
            channel_spans += 1
        elif kind == "culvert_portal":
            var point := Vector2(float(item.world_x), float(item.world_z))
            var outward := Vector2(float(item.out_x), float(item.out_z))
            if outward.length_squared() < 0.000001:
                continue
            outward = outward.normalized()
            var y := float(height_sampler.call(point.x, point.y))
            if not is_finite(y):
                continue
            var width := clampf(float(item.get("width_m", DEFAULT_CULVERT_WIDTH_M)), MIN_WIDTH_M, MAX_WIDTH_M)
            _append_portal(point, outward, y, width, tile_origin, vertices, normals, colors, indices)
            culvert_portals += 1
    return {"vertices": vertices, "normals": normals, "colors": colors, "indices": indices,
        "channel_spans": channel_spans, "culvert_portals": culvert_portals}

func _append_portal(point: Vector2, outward: Vector2, terrain_y: float, width: float,
        tile_origin: Vector2, vertices: PackedVector3Array, normals: PackedVector3Array,
        colors: PackedColorArray, indices: PackedInt32Array) -> void:
    var lateral2 := Vector2(-outward.y, outward.x).normalized()
    var center2 := point + outward * 0.03
    var lateral := Vector3(lateral2.x, 0.0, lateral2.y)
    var center := Vector3(center2.x - tile_origin.x, terrain_y - 0.08, center2.y - tile_origin.y)
    var opening_height := clampf(width * 0.75, 0.45, 2.50)
    var frame := clampf(width * 0.16, 0.10, 0.30)
    var inner_half := width * 0.5
    var outer_half := inner_half + frame
    var inner_left_bottom := center - lateral * inner_half
    var inner_right_bottom := center + lateral * inner_half
    var inner_left_top := inner_left_bottom + Vector3.UP * opening_height
    var inner_right_top := inner_right_bottom + Vector3.UP * opening_height
    var outer_left_bottom := center - lateral * outer_half - Vector3.UP * frame
    var outer_right_bottom := center + lateral * outer_half - Vector3.UP * frame
    var outer_left_top := center - lateral * outer_half + Vector3.UP * (opening_height + frame)
    var outer_right_top := center + lateral * outer_half + Vector3.UP * (opening_height + frame)
    var dark := Color(0.08, 0.09, 0.08, 1.0)
    var concrete := Color(0.44, 0.44, 0.41, 1.0)
    _append_quad(inner_left_bottom, inner_right_bottom, inner_right_top, inner_left_top, dark, vertices, normals, colors, indices)
    _append_quad(outer_left_bottom, inner_left_bottom, inner_left_top, outer_left_top, concrete, vertices, normals, colors, indices)
    _append_quad(inner_right_bottom, outer_right_bottom, outer_right_top, inner_right_top, concrete, vertices, normals, colors, indices)
    _append_quad(outer_left_bottom, outer_right_bottom, inner_right_bottom, inner_left_bottom, concrete.darkened(0.06), vertices, normals, colors, indices)
    _append_quad(inner_left_top, inner_right_top, outer_right_top, outer_left_top, concrete.lightened(0.05), vertices, normals, colors, indices)

func _append_quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, color: Color,
        vertices: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray,
        indices: PackedInt32Array) -> void:
    var normal := (b - a).cross(c - a)
    if normal.length_squared() < 0.0000001:
        return
    normal = normal.normalized()
    var base := vertices.size()
    for point in [a, b, c, d]:
        vertices.append(point)
        normals.append(normal)
        colors.append(color)
    indices.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))

func _default_width(kind: String) -> float:
    if kind == "drain":
        return DEFAULT_DRAIN_WIDTH_M
    if kind == "culvert":
        return DEFAULT_CULVERT_WIDTH_M
    return DEFAULT_DITCH_WIDTH_M

func _drainage_material() -> StandardMaterial3D:
    if _material != null:
        return _material
    _material = StandardMaterial3D.new()
    _material.vertex_color_use_as_albedo = true
    _material.roughness = 0.94
    _material.metallic = 0.0
    _material.cull_mode = BaseMaterial3D.CULL_DISABLED
    return _material
