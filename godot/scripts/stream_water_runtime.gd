extends Node
class_name YardmanStreamWaterRuntime

const References = preload("res://scripts/reference_assets.gd")
const StreamShader = preload("res://shaders/stream_water.gdshader")

const ROOTS := [
    "user://yardman/packs/hydrology/",
    "res://data/hydrology/",
]
const MANIFEST_POLL_SECONDS := 2.0
const MAX_STREAMS_PER_TILE := 256
const MAX_SEGMENTS_PER_TILE := 8192

var _game: Node
var _roads: Variant
var _terrain: Variant
var _manifest: Dictionary = {}
var _root: String = ""
var _tile_files: Dictionary = {}
var _loaded: Dictionary = {}
var _queue: Array[Vector2i] = []
var _thread: Thread
var _job_tile := Vector2i(999999, 999999)
var _poll_clock: float = 0.0
var _material: ShaderMaterial

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    _make_material()
    set_process(true)
    call_deferred("_try_attach")

func _exit_tree() -> void:
    if _thread != null and _thread.is_started():
        _thread.wait_to_finish()

func _process(delta: float) -> void:
    if _game == null:
        _try_attach()
        return
    if _manifest.is_empty():
        _poll_clock += delta
        if _poll_clock >= MANIFEST_POLL_SECONDS:
            _poll_clock = 0.0
            if _load_manifest():
                _queue_loaded_terrain_tiles()
    _poll_job()
    _start_job()

func _try_attach() -> void:
    if get_tree() == null:
        return
    var candidate: Node = get_tree().current_scene
    if candidate == null:
        return
    var roads: Variant = candidate.get("roads")
    var terrain: Variant = candidate.get("terrain")
    if roads == null or terrain == null:
        call_deferred("_try_attach")
        return
    _game = candidate
    _roads = roads
    _terrain = terrain
    _terrain.tile_ready.connect(_on_tile_ready)
    _terrain.tile_removed.connect(_on_tile_removed)
    if _load_manifest():
        _queue_loaded_terrain_tiles()

func _make_material() -> void:
    _material = ShaderMaterial.new()
    _material.shader = StreamShader
    for binding: Array in [
        ["reference_surface", "has_reference_surface", "water_surface.png"],
        ["reference_foam", "has_reference_foam", "water_foam.png"],
        ["reference_caustics", "has_reference_caustics", "water_caustics.png"],
    ]:
        var texture: Texture2D = References.texture(str(binding[2]))
        if texture != null:
            _material.set_shader_parameter(str(binding[0]), texture)
            _material.set_shader_parameter(str(binding[1]), true)

func _load_manifest() -> bool:
    for candidate_root: String in ROOTS:
        var root: String = candidate_root
        var path: String = root + "manifest.json"
        if not FileAccess.file_exists(path):
            continue
        var raw_payload: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
        if not raw_payload is Dictionary:
            continue
        var payload: Dictionary = raw_payload as Dictionary
        if int(payload.get("format_version", 0)) != 1:
            continue
        var tile_size: float = float(payload.get("tile_size", 0.0))
        if _roads != null and tile_size > 0.0 and absf(tile_size - float(_roads.tile_size)) > 0.01:
            push_error("Hydrology pack tile grid differs from Yardman world grid")
            continue
        var files: Dictionary = {}
        for raw_tile: Variant in payload.get("tiles", []):
            if not raw_tile is Dictionary:
                continue
            var tile: Dictionary = raw_tile as Dictionary
            var filename: String = str(tile.get("file", ""))
            if filename.is_empty() or filename.contains("..") or filename.contains("/") or filename.contains("\\"):
                continue
            files[_tile_key(Vector2i(int(tile.get("x", 0)), int(tile.get("z", 0))))] = filename
        _manifest = payload
        _root = root
        _tile_files = files
        print("Yardman hydrology pack: %d streamed tiles from %s" % [_tile_files.size(), _root])
        return true
    return false

func _queue_loaded_terrain_tiles() -> void:
    if _terrain == null:
        return
    for raw_key: Variant in _terrain._loaded.keys():
        var tile: Vector2i = _roads._key_tile(str(raw_key))
        _queue_tile(tile)

func _on_tile_ready(tile: Vector2i) -> void:
    _queue_tile(tile)

func _on_tile_removed(tile: Vector2i) -> void:
    var key: String = _tile_key(tile)
    _loaded.erase(key)
    _queue.erase(tile)
    if _job_tile == tile:
        _job_tile = Vector2i(999999, 999999)

func _queue_tile(tile: Vector2i) -> void:
    if _manifest.is_empty():
        return
    var key: String = _tile_key(tile)
    if not _tile_files.has(key) or _loaded.has(key) or _queue.has(tile) or _job_tile == tile:
        return
    _queue.append(tile)

func _start_job() -> void:
    if _thread != null or _queue.is_empty() or _manifest.is_empty():
        return
    while not _queue.is_empty():
        var tile: Vector2i = _queue.pop_front()
        var key: String = _tile_key(tile)
        if not _tile_files.has(key) or not bool(_terrain.is_tile_ready(tile)):
            continue
        _job_tile = tile
        var path: String = _root + str(_tile_files[key])
        _thread = Thread.new()
        if _thread.start(_read_tile.bind(path)) != OK:
            _thread = null
            _job_tile = Vector2i(999999, 999999)
        return

func _poll_job() -> void:
    if _thread == null or _thread.is_alive():
        return
    var payload: Dictionary = _thread.wait_to_finish()
    _thread = null
    var tile: Vector2i = _job_tile
    _job_tile = Vector2i(999999, 999999)
    if payload.has("error"):
        push_error(str(payload.error))
        return
    if not bool(_terrain.is_tile_ready(tile)):
        return
    _build_tile(tile, payload)

static func _read_tile(path: String) -> Dictionary:
    if not FileAccess.file_exists(path):
        return {"error": "Missing hydrology tile: " + path}
    var raw_payload: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
    if not raw_payload is Dictionary:
        return {"error": "Invalid hydrology tile: " + path}
    var payload: Dictionary = raw_payload as Dictionary
    if not payload.get("streams", null) is Array:
        return {"error": "Invalid hydrology tile: " + path}
    return payload

func _build_tile(tile: Vector2i, payload: Dictionary) -> void:
    var tile_key: String = str(_roads._tile_key(tile.x, tile.y))
    var parent: Variant = _terrain._loaded.get(tile_key)
    if not parent is Node3D:
        return
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var uvs := PackedVector2Array()
    var colors := PackedColorArray()
    var indices := PackedInt32Array()
    var stream_count: int = 0
    var segment_count: int = 0
    for raw_stream: Variant in payload.get("streams", []):
        if stream_count >= MAX_STREAMS_PER_TILE or segment_count >= MAX_SEGMENTS_PER_TILE:
            break
        if not raw_stream is Dictionary:
            continue
        var stream: Dictionary = raw_stream as Dictionary
        var points: Array = stream.get("points", [])
        if points.size() < 2:
            continue
        var width: float = clampf(float(stream.get("width_m", 2.0)), 0.45, 80.0)
        var flow: float = clampf(float(stream.get("flow_mps", 0.7)), 0.05, 6.0)
        var station: float = 0.0
        for i: int in range(points.size() - 1):
            if segment_count >= MAX_SEGMENTS_PER_TILE:
                break
            var a_raw: Variant = points[i]
            var b_raw: Variant = points[i + 1]
            if not a_raw is Array or not b_raw is Array:
                continue
            var a_data: Array = a_raw as Array
            var b_data: Array = b_raw as Array
            if a_data.size() < 2 or b_data.size() < 2:
                continue
            var a_world: Vector2 = _point_xz(a_data)
            var b_world: Vector2 = _point_xz(b_data)
            var delta: Vector2 = b_world - a_world
            var length_m: float = delta.length()
            if length_m < 0.25:
                continue
            var a_y: float = _point_y(a_data, a_world)
            var b_y: float = _point_y(b_data, b_world)
            if not is_finite(a_y) or not is_finite(b_y):
                continue
            var side: Vector2 = Vector2(-delta.y, delta.x).normalized() * width * 0.5
            var base: int = vertices.size()
            var tile_x: float = float(tile.x) * float(_terrain.tile_size)
            var tile_z: float = float(tile.y) * float(_terrain.tile_size)
            var left_a := Vector3(a_world.x + side.x - tile_x, a_y + 0.045, a_world.y + side.y - tile_z)
            var right_a := Vector3(a_world.x - side.x - tile_x, a_y + 0.045, a_world.y - side.y - tile_z)
            var left_b := Vector3(b_world.x + side.x - tile_x, b_y + 0.045, b_world.y + side.y - tile_z)
            var right_b := Vector3(b_world.x - side.x - tile_x, b_y + 0.045, b_world.y - side.y - tile_z)
            vertices.append_array(PackedVector3Array([left_a, right_a, left_b, right_b]))
            normals.append_array(PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP]))
            var v0: float = station / 4.0
            var v1: float = (station + length_m) / 4.0
            uvs.append_array(PackedVector2Array([Vector2(0.0, v0), Vector2(1.0, v0), Vector2(0.0, v1), Vector2(1.0, v1)]))
            var flow_channel: float = flow / 6.0
            colors.append_array(PackedColorArray([
                Color(0.0, flow_channel, 0.0, 1.0), Color(0.0, flow_channel, 0.0, 1.0),
                Color(0.0, flow_channel, 0.0, 1.0), Color(0.0, flow_channel, 0.0, 1.0)
            ]))
            indices.append_array(PackedInt32Array([base, base + 2, base + 1, base + 1, base + 2, base + 3]))
            station += length_m
            segment_count += 1
        stream_count += 1
    if vertices.is_empty():
        _loaded[_tile_key(tile)] = null
        return
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = normals
    arrays[Mesh.ARRAY_TEX_UV] = uvs
    arrays[Mesh.ARRAY_COLOR] = colors
    arrays[Mesh.ARRAY_INDEX] = indices
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    mesh.surface_set_material(0, _material)
    var instance := MeshInstance3D.new()
    instance.name = "RunningWater_%d_%d" % [tile.x, tile.y]
    instance.mesh = mesh
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    instance.visibility_range_end = _draw_distance()
    instance.extra_cull_margin = 4.0
    (parent as Node3D).add_child(instance)
    _loaded[_tile_key(tile)] = instance
    print("Yardman running water tile %s: streams=%d segments=%d" % [_tile_key(tile), stream_count, segment_count])

func _point_xz(data: Array) -> Vector2:
    if data.size() >= 3:
        return Vector2(float(data[0]), float(data[2]))
    return Vector2(float(data[0]), float(data[1]))

func _point_y(data: Array, xz: Vector2) -> float:
    if data.size() >= 3:
        return float(data[1])
    return float(_terrain.height_at(xz.x, xz.y))

func _draw_distance() -> float:
    if _game == null:
        return 700.0
    var visuals: Variant = _game.get("visuals")
    var quality: String = str(visuals.get("quality")) if visuals != null else "Balanced"
    match quality:
        "Performance": return 480.0
        "Quality": return 1000.0
        "Ultra": return 1400.0
        _: return 760.0

func _tile_key(tile: Vector2i) -> String:
    return "%d:%d" % [tile.x, tile.y]
