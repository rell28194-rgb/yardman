extends Node3D
class_name JamaicaBuildingOverview

const OverviewShader = preload("res://shaders/building_overview.gdshader")

var building_streamer
var coordinates
var target: Node3D
var data_root := "res://data/buildings"
var tile_size := 4096.0
var far_distance := 5600.0
var near_distance := 1200.0
var refresh_interval := 0.30
var max_io_jobs := 2
var max_instances_per_frame := 1400
var geometry_budget_us := 1100
var max_tile_instances := 32768

var _material: ShaderMaterial
var _box_mesh: BoxMesh
var _tile_files: Dictionary = {}
var _wanted: Dictionary = {}
var _loaded: Dictionary = {}
var _jobs: Dictionary = {}
var _failed: Dictionary = {}
var _queue: Array[String] = []
var _build: Dictionary = {}
var _refresh_clock := 0.0
var _last_world := Vector2(INF, INF)

func configure(streamer) -> void:
    building_streamer = streamer
    coordinates = streamer.coordinates
    target = streamer.target
    data_root = streamer.data_root
    tile_size = streamer.tile_size

func _ready() -> void:
    _material = ShaderMaterial.new()
    _material.shader = OverviewShader
    _material.set_shader_parameter("near_distance", near_distance)
    _material.set_shader_parameter("far_distance", far_distance)
    _box_mesh = BoxMesh.new()
    _box_mesh.size = Vector3.ONE
    _box_mesh.material = _material
    _load_manifest()
    _refresh(true)

func _process(delta: float) -> void:
    if building_streamer != null:
        target = building_streamer.target
    _refresh_clock += delta
    if _refresh_clock >= refresh_interval:
        _refresh_clock = 0.0
        _refresh(false)
    _poll_jobs()
    _prepare_instances()
    _start_jobs()

func _exit_tree() -> void:
    for job in _jobs.values():
        var thread: Thread = job.thread
        if thread.is_started():
            thread.wait_to_finish()
    _jobs.clear()
    if not _build.is_empty():
        _build.root.free()
        _build.clear()

func _load_manifest() -> void:
    if building_streamer == null or coordinates == null:
        return
    var manifest: Dictionary = building_streamer.manifest
    if manifest.is_empty():
        var path := data_root + "/manifest.json"
        if FileAccess.file_exists(path):
            var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
            if parsed is Dictionary:
                manifest = parsed
    var overview: Dictionary = manifest.get("far_overview", {})
    if int(overview.get("format", 0)) != 1:
        return
    tile_size = float(overview.get("tile_size", tile_size))
    near_distance = float(overview.get("near_handoff_m", near_distance))
    far_distance = float(overview.get("far_distance_m", far_distance))
    _material.set_shader_parameter("near_distance", near_distance)
    _material.set_shader_parameter("far_distance", far_distance)
    _tile_files.clear()
    for entry: Variant in manifest.get("tiles", []):
        if not entry is Dictionary:
            continue
        var filename := str(entry.get("far_file", ""))
        var count := int(entry.get("far_instances", 0))
        if filename.is_empty() or count <= 0:
            continue
        if count > max_tile_instances:
            push_error("Building HLOD tile exceeds runtime instance bound: " + filename)
            continue
        _tile_files[_key(Vector2i(int(entry.x), int(entry.z)))] = filename
    print("Yardman far buildings: %d overview tiles" % _tile_files.size())

func _key(tile: Vector2i) -> String:
    return "%d:%d" % [tile.x, tile.y]

func _tile(key: String) -> Vector2i:
    var pieces := key.split(":")
    return Vector2i(int(pieces[0]), int(pieces[1]))

func _world_position() -> Vector2:
    if target == null or coordinates == null:
        return Vector2.ZERO
    var world: PackedFloat64Array = coordinates.local_to_world(target.global_position)
    return Vector2(world[0], world[2])

func _tile_distance(world: Vector2, tile: Vector2i) -> float:
    var minimum := Vector2(float(tile.x) * tile_size, float(tile.y) * tile_size)
    var maximum := minimum + Vector2.ONE * tile_size
    var dx := maxf(maxf(minimum.x - world.x, 0.0), world.x - maximum.x)
    var dz := maxf(maxf(minimum.y - world.y, 0.0), world.y - maximum.y)
    return Vector2(dx, dz).length()

func _tile_position(tile: Vector2i) -> Vector3:
    return coordinates.world_to_local(float(tile.x) * tile_size, float(tile.y) * tile_size, 0.0)

func _refresh(force: bool) -> void:
    if _tile_files.is_empty() or target == null or coordinates == null:
        return
    var world := _world_position()
    if not force and world.distance_squared_to(_last_world) < 512.0 * 512.0:
        # Keep already-built roots exactly registered through floating-origin
        # shifts even before the next residency decision.
        for key in _loaded.keys():
            _loaded[key].position = _tile_position(_tile(str(key)))
        if not _build.is_empty():
            _build.root.position = _tile_position(_build.tile)
        return
    _last_world = world
    var current := coordinates.tile_for(world.x, world.y)
    _wanted.clear()
    _queue.clear()
    var radius := ceili(far_distance / tile_size) + 1
    for dz in range(-radius, radius + 1):
        for dx in range(-radius, radius + 1):
            var tile := current + Vector2i(dx, dz)
            var key := _key(tile)
            if not _tile_files.has(key) or _tile_distance(world, tile) > far_distance + 320.0:
                continue
            _wanted[key] = true
            if not _loaded.has(key) and not _jobs.has(key) and str(_build.get("key", "")) != key and not _failed.has(key):
                _queue.append(key)
    _queue.sort_custom(func(a: String, b: String) -> bool:
        return _tile_distance(world, _tile(a)) < _tile_distance(world, _tile(b)))
    for key in _loaded.keys():
        if not _wanted.has(key):
            _loaded[key].queue_free()
            _loaded.erase(key)
        else:
            _loaded[key].position = _tile_position(_tile(str(key)))
    for key in _failed.keys():
        if not _wanted.has(key):
            _failed.erase(key)
    if not _build.is_empty():
        if not _wanted.has(_build.key):
            _build.root.free()
            _build.clear()
        else:
            _build.root.position = _tile_position(_build.tile)

func _start_jobs() -> void:
    while _jobs.size() < max_io_jobs and not _queue.is_empty():
        var key: String = _queue.pop_front()
        if not _wanted.has(key):
            continue
        var path := data_root + "/" + str(_tile_files[key])
        var thread := Thread.new()
        if thread.start(_read_tile.bind(path, max_tile_instances)) != OK:
            _failed[key] = true
            push_error("Cannot start building HLOD reader: " + key)
            continue
        _jobs[key] = {"thread": thread}

static func _read_tile(path: String, instance_limit: int) -> Dictionary:
    if not FileAccess.file_exists(path):
        return {"error": "Missing building HLOD tile: " + path}
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null or file.get_length() <= 0 or file.get_length() > 32 * 1024 * 1024:
        return {"error": "Invalid building HLOD compressed size: " + path}
    var compressed := file.get_buffer(file.get_length())
    var raw := compressed.decompress_dynamic(64 * 1024 * 1024, FileAccess.COMPRESSION_GZIP)
    if raw.is_empty():
        return {"error": "Building HLOD decompression failed: " + path}
    var parsed: Variant = JSON.parse_string(raw.get_string_from_utf8())
    if not parsed is Dictionary or int(parsed.get("format", 0)) != 1 or not parsed.get("instances", null) is Array:
        return {"error": "Invalid building HLOD payload: " + path}
    if parsed.instances.size() > instance_limit:
        return {"error": "Building HLOD instance count exceeds bound: " + path}
    return parsed

func _poll_jobs() -> void:
    for key in _jobs.keys():
        var thread: Thread = _jobs[key].thread
        if thread.is_alive():
            continue
        if not _wanted.has(key):
            thread.wait_to_finish()
            _jobs.erase(key)
            continue
        if not _build.is_empty():
            continue
        var payload: Dictionary = thread.wait_to_finish()
        _jobs.erase(key)
        if payload.has("error"):
            _failed[key] = true
            push_error(str(payload.error))
            continue
        var tile := _tile(str(key))
        if payload.get("tile", []) != [tile.x, tile.y]:
            _failed[key] = true
            push_error("Building HLOD tile identity mismatch: " + key)
            continue
        var instances: Array = payload.instances
        var multimesh := MultiMesh.new()
        multimesh.transform_format = MultiMesh.TRANSFORM_3D
        multimesh.mesh = _box_mesh
        multimesh.instance_count = instances.size()
        var instance := MultiMeshInstance3D.new()
        instance.name = "BuildingOverview_%d_%d" % [tile.x, tile.y]
        instance.multimesh = multimesh
        instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        var root_node := Node3D.new()
        root_node.name = "BuildingOverviewTile_%d_%d" % [tile.x, tile.y]
        root_node.position = _tile_position(tile)
        root_node.add_child(instance)
        _build = {"key": key, "tile": tile, "root": root_node, "multimesh": multimesh,
            "records": instances, "cursor": 0}

func _prepare_instances() -> void:
    if _build.is_empty():
        return
    var started := Time.get_ticks_usec()
    var processed := 0
    var records: Array = _build.records
    while _build.cursor < records.size() and processed < max_instances_per_frame:
        var raw: Variant = records[_build.cursor]
        var index: int = _build.cursor
        _build.cursor += 1
        processed += 1
        if not raw is Array or raw.size() != 8:
            _failed[_build.key] = true
            push_error("Invalid building HLOD instance record: " + str(_build.key))
            _build.root.free()
            _build.clear()
            return
        var center_x := float(raw[0])
        var base_y := float(raw[1])
        var center_z := float(raw[2])
        var width := float(raw[3])
        var height := float(raw[4])
        var depth := float(raw[5])
        var yaw := float(raw[6])
        if not Vector3(center_x, base_y, center_z).is_finite() or not Vector3(width, height, depth).is_finite() or not is_finite(yaw) or minf(width, minf(height, depth)) <= 0.0:
            _failed[_build.key] = true
            push_error("Non-finite building HLOD transform: " + str(_build.key))
            _build.root.free()
            _build.clear()
            return
        var basis := Basis(Vector3.UP, yaw).scaled(Vector3(width, height, depth))
        var pose := Transform3D(basis, Vector3(center_x, base_y + height * 0.5, center_z))
        _build.multimesh.set_instance_transform(index, pose)
        if Time.get_ticks_usec() - started >= geometry_budget_us:
            break
    if _build.cursor >= records.size():
        var root_node: Node3D = _build.root
        var key: String = _build.key
        add_child(root_node)
        _loaded[key] = root_node
        _build.clear()

func loaded_tile_count() -> int:
    return _loaded.size()

func inflight_count() -> int:
    return _queue.size() + _jobs.size() + (0 if _build.is_empty() else 1)