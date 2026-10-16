extends Node

# Geographic authority is only the compiled Jamaica OSM barrier=guard_rail
# dataset. Recovered source-game transforms never become placement authority.
# Public runtime uses an original procedural metal fallback; accepted recovered
# Highway geometry remains private recovery evidence for visual calibration.
const MAX_SPAN_M := 3.75
const MAX_SPANS_PER_TILE := 256
const BEAM_HEIGHT_M := 0.30
const BEAM_DEPTH_M := 0.14
const BEAM_CENTER_Y_M := 0.62
const POST_HEIGHT_M := 0.78
const POST_WIDTH_M := 0.13
const VISIBILITY_RANGE_M := 900.0
const DEFAULT_TILE_SIZE_M := 4096.0
const QUERY_MAX_RADIUS_M := 96.0

var _terrain: Node
var _connected := false
var _beam_mesh: BoxMesh
var _post_mesh: BoxMesh
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
    var tile_root := _terrain.get_node_or_null("TerrainTile_%d_%d" % [tile.x, tile.y]) as Node3D
    if tile_root != null:
        _decorate(tile, tile_root)

func _on_terrain_tile_removed(_tile: Vector2i) -> void:
    pass

func _decorate(tile: Vector2i, tile_root: Node3D) -> void:
    var existing := tile_root.get_node_or_null("GuardRailProxy")
    if existing != null:
        existing.queue_free()
    var records := _load_tile(tile)
    if records.is_empty():
        return
    var plan := placement_plan(records, tile, float(_terrain.tile_size), MAX_SPAN_M)
    if plan.is_empty():
        return
    _ensure_meshes()
    if _beam_mesh == null or _post_mesh == null:
        return

    var beam_transforms: Array[Transform3D] = []
    var post_transforms: Array[Transform3D] = []
    var seen_posts: Dictionary = {}
    for item: Dictionary in plan:
        var a2 := Vector2(float(item.world_ax), float(item.world_az))
        var b2 := Vector2(float(item.world_bx), float(item.world_bz))
        var y0 := float(_terrain.height_at(a2.x, a2.y))
        var y1 := float(_terrain.height_at(b2.x, b2.y))
        if not is_finite(y0) or not is_finite(y1):
            continue
        var tile_origin := Vector2(float(tile.x) * float(_terrain.tile_size), float(tile.y) * float(_terrain.tile_size))
        var a3 := Vector3(a2.x - tile_origin.x, y0 + BEAM_CENTER_Y_M, a2.y - tile_origin.y)
        var b3 := Vector3(b2.x - tile_origin.x, y1 + BEAM_CENTER_Y_M, b2.y - tile_origin.y)
        var delta := b3 - a3
        var length := delta.length()
        if length < 0.05:
            continue
        var x_axis := delta / length
        var z_axis := x_axis.cross(Vector3.UP)
        if z_axis.length_squared() < 0.0001:
            z_axis = Vector3.FORWARD
        else:
            z_axis = z_axis.normalized()
        var y_axis := z_axis.cross(x_axis).normalized()
        var beam_basis := Basis(x_axis * length, y_axis, z_axis)
        beam_transforms.append(Transform3D(beam_basis, (a3 + b3) * 0.5))

        for endpoint in [
            {"key": str(item.source_way) + ":" + str(item.start_key), "point": a2, "ground": y0},
            {"key": str(item.source_way) + ":" + str(item.end_key), "point": b2, "ground": y1},
        ]:
            var key := str(endpoint.key)
            if seen_posts.has(key):
                continue
            seen_posts[key] = true
            var point: Vector2 = endpoint.point
            post_transforms.append(Transform3D(Basis.IDENTITY, Vector3(
                point.x - tile_origin.x,
                float(endpoint.ground) + POST_HEIGHT_M * 0.5,
                point.y - tile_origin.y
            )))

    if beam_transforms.is_empty():
        return
    var proxy := Node3D.new()
    proxy.name = "GuardRailProxy"
    proxy.set_meta("placement_source", "explicit Jamaica OSM barrier=guard_rail ways only")
    proxy.set_meta("visual_style", "original procedural metal fallback; recovered Highway geometry kept private")
    proxy.set_meta("guardrail_spans", beam_transforms.size())
    proxy.set_meta("guardrail_posts", post_transforms.size())
    proxy.add_child(_make_multimesh_instance("GuardRailBeams", _beam_mesh, beam_transforms))
    if not post_transforms.is_empty():
        proxy.add_child(_make_multimesh_instance("GuardRailPosts", _post_mesh, post_transforms))
    tile_root.add_child(proxy)

func _make_multimesh_instance(name_value: String, mesh: Mesh, transforms: Array[Transform3D]) -> MultiMeshInstance3D:
    var multi := MultiMesh.new()
    multi.transform_format = MultiMesh.TRANSFORM_3D
    multi.mesh = mesh
    multi.instance_count = transforms.size()
    for index in range(transforms.size()):
        multi.set_instance_transform(index, transforms[index])
    var instance := MultiMeshInstance3D.new()
    instance.name = name_value
    instance.multimesh = multi
    instance.visibility_range_end = VISIBILITY_RANGE_M
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    return instance

func _cache_key(tile: Vector2i) -> String:
    return "%d:%d" % [tile.x, tile.y]

func _load_tile(tile: Vector2i) -> Array:
    var key := _cache_key(tile)
    if _record_cache.has(key):
        return _record_cache[key]
    var path := "res://data/roads/guardrails/tile_%d_%d.json" % [tile.x, tile.y]
    if not FileAccess.file_exists(path):
        _record_cache[key] = []
        return _record_cache[key]
    var payload = JSON.parse_string(FileAccess.get_file_as_string(path))
    if not payload is Dictionary or not payload.get("guard_rails", null) is Array:
        push_warning("Invalid Yardman guard-rail tile: " + path)
        _record_cache[key] = []
        return _record_cache[key]
    _record_cache[key] = payload.guard_rails
    return _record_cache[key]

static func _segment_distance_squared(point: Vector2, a: Vector2, b: Vector2) -> float:
    var direction := b - a
    var length_squared := direction.length_squared()
    if length_squared < 0.000001:
        return point.distance_squared_to(a)
    var fraction := clampf((point - a).dot(direction) / length_squared, 0.0, 1.0)
    return point.distance_squared_to(a + direction * fraction)

func has_mapped_guardrail_near(world_point: Vector2, radius_m: float) -> bool:
    """Return true only when explicit compiled Jamaica guard-rail evidence is near.

    Inferred road-safety systems use this as an authority gate so they cannot draw a
    second rail over sourced OSM geometry. The query is spatially bounded and reads
    only the few guard-rail tiles intersecting the requested radius.
    """
    if not is_finite(world_point.x) or not is_finite(world_point.y) or not is_finite(radius_m) or radius_m <= 0.0:
        return false
    var radius := clampf(radius_m, 0.25, QUERY_MAX_RADIUS_M)
    var tile_size := DEFAULT_TILE_SIZE_M
    if _terrain != null and "tile_size" in _terrain:
        tile_size = float(_terrain.tile_size)
    if not is_finite(tile_size) or tile_size <= 0.0:
        return false
    var first := Vector2i(floori((world_point.x - radius) / tile_size), floori((world_point.y - radius) / tile_size))
    var last := Vector2i(floori((world_point.x + radius) / tile_size), floori((world_point.y + radius) / tile_size))
    var radius_squared := radius * radius
    for tz in range(first.y, last.y + 1):
        for tx in range(first.x, last.x + 1):
            for raw_record in _load_tile(Vector2i(tx, tz)):
                if not raw_record is Dictionary or str(raw_record.get("barrier", "")) != "guard_rail":
                    continue
                var start_raw = raw_record.get("start", [])
                var end_raw = raw_record.get("end", [])
                if not start_raw is Array or not end_raw is Array or start_raw.size() < 2 or end_raw.size() < 2:
                    continue
                var a := Vector2(float(start_raw[0]), float(start_raw[1]))
                var b := Vector2(float(end_raw[0]), float(end_raw[1]))
                if not is_finite(a.x) or not is_finite(a.y) or not is_finite(b.x) or not is_finite(b.y):
                    continue
                if _segment_distance_squared(world_point, a, b) <= radius_squared:
                    return true
    return false

func placement_plan(records: Array, tile: Vector2i, tile_size: float, max_span_m: float = MAX_SPAN_M) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    if tile_size <= 0.0 or max_span_m <= 0.0 or not is_finite(tile_size) or not is_finite(max_span_m):
        return result
    for record in records:
        if result.size() >= MAX_SPANS_PER_TILE:
            break
        if not record is Dictionary or str(record.get("barrier", "")) != "guard_rail":
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
        var spans := maxi(1, int(ceil(length / max_span_m)))
        var source_way := str(record.get("source_way", ""))
        if source_way.is_empty():
            continue
        for index in range(spans):
            if result.size() >= MAX_SPANS_PER_TILE:
                break
            var t0 := float(index) / float(spans)
            var t1 := float(index + 1) / float(spans)
            var p0 := a.lerp(b, t0)
            var p1 := a.lerp(b, t1)
            result.append({
                "source_way": source_way,
                "world_ax": p0.x,
                "world_az": p0.y,
                "world_bx": p1.x,
                "world_bz": p1.y,
                "start_key": "%d:%d:a" % [int(record.get("segment", 0)), index],
                "end_key": "%d:%d:b" % [int(record.get("segment", 0)), index],
                "material": str(record.get("material", "unspecified")),
            })
    return result

func _ensure_meshes() -> void:
    if _beam_mesh != null and _post_mesh != null:
        return
    _material = StandardMaterial3D.new()
    _material.albedo_color = Color(0.48, 0.50, 0.52, 1.0)
    _material.metallic = 0.72
    _material.roughness = 0.38
    _beam_mesh = BoxMesh.new()
    _beam_mesh.size = Vector3(1.0, BEAM_HEIGHT_M, BEAM_DEPTH_M)
    _beam_mesh.material = _material
    _post_mesh = BoxMesh.new()
    _post_mesh.size = Vector3(POST_WIDTH_M, POST_HEIGHT_M, POST_WIDTH_M)
    _post_mesh.material = _material
