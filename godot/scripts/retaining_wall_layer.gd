extends Node

# Hard retaining structures are placed only where Jamaica OSM explicitly records
# barrier=retaining_wall. Inferred road cut/fill geometry remains soft earthworks
# and is never promoted into a concrete/stone wall by this layer.
const MAX_SPAN_M := 5.0
const MAX_SPANS_PER_TILE := 512
const DEFAULT_HEIGHT_M := 1.60
const MIN_HEIGHT_M := 0.40
const MAX_HEIGHT_M := 30.0
const WALL_DEPTH_M := 0.36
const EMBED_M := 0.12
const VISIBILITY_RANGE_M := 1300.0

var _terrain: Node
var _connected := false
var _material: StandardMaterial3D

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
    _connected = true
    set_process(false)

func _on_terrain_tile(tile: Vector2i) -> void:
    var tile_root := _terrain.get_node_or_null("TerrainTile_%d_%d" % [tile.x, tile.y]) as Node3D
    if tile_root != null:
        _decorate(tile, tile_root)

func _decorate(tile: Vector2i, tile_root: Node3D) -> void:
    var existing := tile_root.get_node_or_null("RetainingWallProxy")
    if existing != null:
        tile_root.remove_child(existing)
        existing.queue_free()
    var records := _load_tile(tile)
    if records.is_empty():
        return
    var plan := placement_plan(records, tile, float(_terrain.tile_size), MAX_SPAN_M)
    if plan.is_empty():
        return
    var tile_origin := Vector2(float(tile.x) * float(_terrain.tile_size), float(tile.y) * float(_terrain.tile_size))
    var geometry := build_geometry(plan, tile_origin, _terrain.height_at)
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
    mesh.surface_set_material(0, _wall_material())

    var proxy := Node3D.new()
    proxy.name = "RetainingWallProxy"
    proxy.set_meta("placement_source", "explicit Jamaica OSM barrier=retaining_wall ways only")
    proxy.set_meta("wall_spans", int(geometry.spans))
    proxy.set_meta("explicit_height_spans", int(geometry.explicit_height_spans))
    proxy.set_meta("fallback_height_spans", int(geometry.fallback_height_spans))

    var instance := MeshInstance3D.new()
    instance.name = "RetainingWalls"
    instance.mesh = mesh
    instance.visibility_range_end = VISIBILITY_RANGE_M
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
    proxy.add_child(instance)

    var faces: PackedVector3Array = geometry.collision_faces
    if not faces.is_empty():
        var shape := ConcavePolygonShape3D.new()
        shape.backface_collision = true
        shape.set_faces(faces)
        var collision := CollisionShape3D.new()
        collision.shape = shape
        var body := StaticBody3D.new()
        body.name = "RetainingWallCollision"
        body.collision_layer = 1
        body.collision_mask = 0
        body.add_child(collision)
        proxy.add_child(body)
    tile_root.add_child(proxy)

func _load_tile(tile: Vector2i) -> Array:
    var path := "res://data/roads/retaining_walls/tile_%d_%d.json" % [tile.x, tile.y]
    if not FileAccess.file_exists(path):
        return []
    var payload = JSON.parse_string(FileAccess.get_file_as_string(path))
    if not payload is Dictionary or not payload.get("retaining_walls", null) is Array:
        push_warning("Invalid Yardman retaining-wall tile: " + path)
        return []
    return payload.retaining_walls

func placement_plan(records: Array, tile: Vector2i, tile_size: float,
        max_span_m: float = MAX_SPAN_M) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    if tile_size <= 0.0 or max_span_m <= 0.0 or not is_finite(tile_size) or not is_finite(max_span_m):
        return result
    for record in records:
        if result.size() >= MAX_SPANS_PER_TILE:
            break
        if not record is Dictionary or str(record.get("barrier", "")) != "retaining_wall":
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
        var explicit_height: bool = record.has("height_m")
        var height := float(record.get("height_m", DEFAULT_HEIGHT_M))
        if not is_finite(height):
            height = DEFAULT_HEIGHT_M
            explicit_height = false
        height = clampf(height, MIN_HEIGHT_M, MAX_HEIGHT_M)
        var spans := maxi(1, int(ceil(length / max_span_m)))
        for index in range(spans):
            if result.size() >= MAX_SPANS_PER_TILE:
                break
            var p0 := a.lerp(b, float(index) / float(spans))
            var p1 := a.lerp(b, float(index + 1) / float(spans))
            result.append({
                "source_way": source_way,
                "world_ax": p0.x,
                "world_az": p0.y,
                "world_bx": p1.x,
                "world_bz": p1.y,
                "height_m": height,
                "height_source": "OSM" if explicit_height else "visual_fallback",
                "material": str(record.get("material", "unspecified")),
            })
    return result

func build_geometry(plan: Array[Dictionary], tile_origin: Vector2, height_sampler: Callable) -> Dictionary:
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var colors := PackedColorArray()
    var indices := PackedInt32Array()
    var collision_faces := PackedVector3Array()
    var spans := 0
    var explicit_height_spans := 0
    var fallback_height_spans := 0
    if not height_sampler.is_valid():
        return {"vertices": vertices, "normals": normals, "colors": colors, "indices": indices,
            "collision_faces": collision_faces, "spans": 0, "explicit_height_spans": 0,
            "fallback_height_spans": 0}
    for item: Dictionary in plan:
        var a2 := Vector2(float(item.world_ax), float(item.world_az))
        var b2 := Vector2(float(item.world_bx), float(item.world_bz))
        var y0 := float(height_sampler.call(a2.x, a2.y))
        var y1 := float(height_sampler.call(b2.x, b2.y))
        if not is_finite(y0) or not is_finite(y1):
            continue
        var horizontal := b2 - a2
        var length := horizontal.length()
        if length < 0.05:
            continue
        var side := Vector2(-horizontal.y, horizontal.x).normalized() * (WALL_DEPTH_M * 0.5)
        var height := clampf(float(item.get("height_m", DEFAULT_HEIGHT_M)), MIN_HEIGHT_M, MAX_HEIGHT_M)
        var base0 := y0 - EMBED_M
        var base1 := y1 - EMBED_M
        var a_left := Vector3(a2.x - tile_origin.x + side.x, base0, a2.y - tile_origin.y + side.y)
        var a_right := Vector3(a2.x - tile_origin.x - side.x, base0, a2.y - tile_origin.y - side.y)
        var b_left := Vector3(b2.x - tile_origin.x + side.x, base1, b2.y - tile_origin.y + side.y)
        var b_right := Vector3(b2.x - tile_origin.x - side.x, base1, b2.y - tile_origin.y - side.y)
        var a_left_top := a_left + Vector3.UP * height
        var a_right_top := a_right + Vector3.UP * height
        var b_left_top := b_left + Vector3.UP * height
        var b_right_top := b_right + Vector3.UP * height
        var color := _material_color(str(item.get("material", "unspecified")))
        _append_face(a_left, b_left, b_left_top, a_left_top, color, vertices, normals, colors, indices, collision_faces)
        _append_face(b_right, a_right, a_right_top, b_right_top, color, vertices, normals, colors, indices, collision_faces)
        _append_face(a_left_top, b_left_top, b_right_top, a_right_top, color.lightened(0.08), vertices, normals, colors, indices, collision_faces)
        _append_face(a_right, b_right, b_left, a_left, color.darkened(0.08), vertices, normals, colors, indices, collision_faces)
        _append_face(a_right, a_left, a_left_top, a_right_top, color, vertices, normals, colors, indices, collision_faces)
        _append_face(b_left, b_right, b_right_top, b_left_top, color, vertices, normals, colors, indices, collision_faces)
        spans += 1
        if str(item.get("height_source", "")) == "OSM":
            explicit_height_spans += 1
        else:
            fallback_height_spans += 1
    return {"vertices": vertices, "normals": normals, "colors": colors, "indices": indices,
        "collision_faces": collision_faces, "spans": spans,
        "explicit_height_spans": explicit_height_spans, "fallback_height_spans": fallback_height_spans}

func _append_face(a: Vector3, b: Vector3, c: Vector3, d: Vector3, color: Color,
        vertices: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray,
        indices: PackedInt32Array, collision_faces: PackedVector3Array) -> void:
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
    collision_faces.append_array(PackedVector3Array([a, b, c, a, c, d]))

func _material_color(material_name: String) -> Color:
    var key := material_name.strip_edges().to_lower()
    if key in ["stone", "rock"]:
        return Color(0.42, 0.40, 0.35, 1.0)
    if key in ["brick", "bricks"]:
        return Color(0.45, 0.28, 0.22, 1.0)
    if key in ["concrete", "cement"]:
        return Color(0.47, 0.47, 0.45, 1.0)
    if key in ["masonry", "block", "concrete_blocks"]:
        return Color(0.50, 0.48, 0.43, 1.0)
    return Color(0.43, 0.42, 0.39, 1.0)

func _wall_material() -> StandardMaterial3D:
    if _material != null:
        return _material
    _material = StandardMaterial3D.new()
    _material.vertex_color_use_as_albedo = true
    _material.roughness = 0.88
    _material.metallic = 0.0
    return _material