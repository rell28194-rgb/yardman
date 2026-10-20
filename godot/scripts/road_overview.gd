extends Node3D
class_name JamaicaRoadOverview

const OverviewShader = preload("res://shaders/road_overview.gdshader")

var road_streamer
var coordinates
var target: Node3D
var data_root := "res://data/roads"
var tile_size := 4096.0
var radius_tiles := 3
var refresh_interval := 0.25
var geometry_budget_us := 900
var max_sectors_per_frame := 2
var near_distance := 1900.0
var far_distance := 14500.0

var _material: ShaderMaterial
var _thread: Thread
var _source: Dictionary = {}
var _wanted: Dictionary = {}
var _loaded: Dictionary = {}
var _queue: Array[String] = []
var _refresh_clock := 0.0
var _last_tile := Vector2i(999999, 999999)
var _failed := false

func configure(streamer) -> void:
    road_streamer = streamer
    coordinates = streamer.coordinates
    target = streamer.target
    data_root = streamer.data_root
    tile_size = streamer.tile_size

func _ready() -> void:
    _material = ShaderMaterial.new()
    _material.shader = OverviewShader
    _material.set_shader_parameter("near_distance", near_distance)
    _material.set_shader_parameter("far_distance", far_distance)
    _begin_load()

func _process(delta: float) -> void:
    if road_streamer != null:
        target = road_streamer.target
    _poll_load()
    _refresh_clock += delta
    if _refresh_clock >= refresh_interval:
        _refresh_clock = 0.0
        _refresh(false)
    _build_queued()

func _exit_tree() -> void:
    if _thread != null and _thread.is_started():
        _thread.wait_to_finish()

func _begin_load() -> void:
    if road_streamer == null or coordinates == null:
        return
    var overview: Dictionary = road_streamer.manifest.get("overview", {})
    if int(overview.get("format", 0)) != 1:
        return
    var filename := str(overview.get("file", ""))
    if filename.is_empty():
        return
    _thread = Thread.new()
    var error := _thread.start(_read_overview.bind(data_root + "/" + filename))
    if error != OK:
        _failed = true
        push_error("Cannot start far-road overview reader")

static func _read_overview(path: String) -> Dictionary:
    if not FileAccess.file_exists(path):
        return {"error": "Missing far-road overview: " + path}
    var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
    if not parsed is Dictionary or int(parsed.get("format", 0)) != 1 or not parsed.get("sectors", null) is Array:
        return {"error": "Invalid far-road overview: " + path}
    if parsed.sectors.size() > 4096:
        return {"error": "Far-road overview sector count exceeds safety bound"}
    return parsed

func _poll_load() -> void:
    if _thread == null or not _thread.is_started() or _thread.is_alive():
        return
    var payload: Dictionary = _thread.wait_to_finish()
    _thread = null
    if payload.has("error"):
        _failed = true
        push_error(str(payload.error))
        return
    if absf(float(payload.get("tile_size", tile_size)) - tile_size) > 0.001:
        _failed = true
        push_error("Far-road overview grid differs from near road grid")
        return
    _source.clear()
    var total_segments := 0
    for sector: Variant in payload.sectors:
        if not sector is Array or sector.size() != 3 or not sector[2] is Array:
            _failed = true
            push_error("Malformed far-road overview sector")
            _source.clear()
            return
        var tile := Vector2i(int(sector[0]), int(sector[1]))
        var segments: Array = sector[2]
        if segments.size() > 50000:
            _failed = true
            push_error("Far-road overview sector exceeds geometry bound")
            _source.clear()
            return
        _source[_key(tile)] = segments
        total_segments += segments.size()
    print("Yardman far roads: %d arterial segments / %d streamed sectors" % [total_segments, _source.size()])
    _refresh(true)

func _key(tile: Vector2i) -> String:
    return "%d:%d" % [tile.x, tile.y]

func _tile(key: String) -> Vector2i:
    var pieces := key.split(":")
    return Vector2i(int(pieces[0]), int(pieces[1]))

func _target_tile() -> Vector2i:
    if target == null or coordinates == null:
        return Vector2i.ZERO
    var world: PackedFloat64Array = coordinates.local_to_world(target.global_position)
    return coordinates.tile_for(world[0], world[2])

func _sector_position(tile: Vector2i) -> Vector3:
    return coordinates.world_to_local(float(tile.x) * tile_size, float(tile.y) * tile_size, 0.0)

func _refresh(force: bool) -> void:
    if _source.is_empty() or target == null or coordinates == null:
        return
    var current := _target_tile()
    if not force and current == _last_tile:
        # A floating-origin rebase can change local placement without changing
        # the canonical sector. Re-register roots against the current origin.
        for key in _loaded.keys():
            _loaded[key].position = _sector_position(_tile(str(key)))
        return
    _last_tile = current
    _wanted.clear()
    _queue.clear()
    for dz in range(-radius_tiles, radius_tiles + 1):
        for dx in range(-radius_tiles, radius_tiles + 1):
            var tile := current + Vector2i(dx, dz)
            var key := _key(tile)
            if not _source.has(key):
                continue
            _wanted[key] = true
            if not _loaded.has(key):
                _queue.append(key)
    _queue.sort_custom(func(a: String, b: String) -> bool:
        return _tile(a).distance_squared_to(current) < _tile(b).distance_squared_to(current))
    for key in _loaded.keys():
        var tile := _tile(str(key))
        if maxi(absi(tile.x - current.x), absi(tile.y - current.y)) > radius_tiles + 1:
            _loaded[key].queue_free()
            _loaded.erase(key)
        else:
            _loaded[key].position = _sector_position(tile)

func _build_queued() -> void:
    if _queue.is_empty():
        return
    var started := Time.get_ticks_usec()
    var built := 0
    while not _queue.is_empty() and built < max_sectors_per_frame:
        var key: String = _queue.pop_front()
        if not _wanted.has(key) or _loaded.has(key) or not _source.has(key):
            continue
        var instance := _make_sector(_tile(key), _source[key])
        if instance != null:
            add_child(instance)
            _loaded[key] = instance
            built += 1
        if Time.get_ticks_usec() - started >= geometry_budget_us:
            break

func _make_sector(tile: Vector2i, segments: Array) -> MeshInstance3D:
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var colors := PackedColorArray()
    var indices := PackedInt32Array()
    var origin_x := float(tile.x) * tile_size
    var origin_z := float(tile.y) * tile_size
    for raw: Variant in segments:
        if not raw is Array or raw.size() != 8:
            continue
        var a := Vector3(float(raw[0]) - origin_x, float(raw[1]) + 0.16, float(raw[2]) - origin_z)
        var b := Vector3(float(raw[3]) - origin_x, float(raw[4]) + 0.16, float(raw[5]) - origin_z)
        if not a.is_finite() or not b.is_finite():
            continue
        var direction := Vector2(b.x - a.x, b.z - a.z)
        if direction.length_squared() < 0.01:
            continue
        var width := clampf(float(raw[6]), 2.0, 24.0)
        var half_width := maxf(width * 0.5, 2.25)
        var side := Vector2(-direction.y, direction.x).normalized() * half_width
        var base := vertices.size()
        vertices.append_array(PackedVector3Array([
            a + Vector3(side.x, 0.0, side.y),
            a - Vector3(side.x, 0.0, side.y),
            b - Vector3(side.x, 0.0, side.y),
            b + Vector3(side.x, 0.0, side.y)]))
        var encoded := Color(width / 64.0, float(int(raw[7])) / 16.0, 0.0, 1.0)
        for index in range(4):
            normals.append(Vector3.UP)
            colors.append(encoded)
        indices.append_array(PackedInt32Array([base, base + 2, base + 1, base, base + 3, base + 2]))
    if vertices.is_empty():
        return null
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = normals
    arrays[Mesh.ARRAY_COLOR] = colors
    arrays[Mesh.ARRAY_INDEX] = indices
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    mesh.surface_set_material(0, _material)
    var instance := MeshInstance3D.new()
    instance.name = "RoadOverview_%d_%d" % [tile.x, tile.y]
    instance.mesh = mesh
    instance.position = _sector_position(tile)
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    return instance

func loaded_sector_count() -> int:
    return _loaded.size()

func queued_sector_count() -> int:
    return _queue.size()

func failed() -> bool:
    return _failed