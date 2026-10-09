extends Node3D
class_name JamaicaRoadStreamer

const CoordinatesScript = preload("res://scripts/world_coordinates.gd")
const GraphScript = preload("res://scripts/road_graph.gd")
signal tile_ready(tile: Vector2i)
signal tile_removed(tile: Vector2i)
signal tile_content_ready(tile: Vector2i, tile_root: Node3D, segments: Array)

var target: Node3D
var data_root := "res://data/roads"
var load_radius := 2
var tile_size := 4096.0
var refresh_interval := 0.25
var max_io_jobs := 2
var max_segments_per_frame := 384
var geometry_budget_us := 2500
var manifest: Dictionary = {}
var coordinates = CoordinatesScript.new()
var graph = GraphScript.new()
var generation := 0
var _refresh_clock := 0.0
var _last_tile := Vector2i(999999, 999999)
var _last_radius := -1
var _tile_files: Dictionary = {}
var _loaded: Dictionary = {}
var _wanted: Dictionary = {}
var _queue: Array[String] = []
var _jobs: Dictionary = {}
var _building: Dictionary = {}
var _failed: Dictionary = {}
var _asphalt_material: StandardMaterial3D
var _dirt_material: StandardMaterial3D

func _ready() -> void:
    _make_materials()
    _load_manifest()
    _refresh_tiles(true)

func _process(delta: float) -> void:
    _refresh_clock += delta
    if _refresh_clock >= refresh_interval:
        _refresh_clock = 0.0
        _refresh_tiles(false)
    _poll_jobs()
    _prepare_geometry()
    _start_jobs()

func _exit_tree() -> void:
    for job in _jobs.values():
        var thread: Thread = job.thread
        if thread.is_started():
            thread.wait_to_finish()
    _jobs.clear()
    if not _building.is_empty():
        _building.root.free()
        _building.clear()

func _make_materials() -> void:
    _asphalt_material = StandardMaterial3D.new()
    _asphalt_material.albedo_color = Color(0.10, 0.105, 0.11)
    _asphalt_material.roughness = 0.92
    _asphalt_material.cull_mode = BaseMaterial3D.CULL_DISABLED
    _dirt_material = StandardMaterial3D.new()
    _dirt_material.albedo_color = Color(0.34, 0.27, 0.18)
    _dirt_material.roughness = 1.0
    _dirt_material.cull_mode = BaseMaterial3D.CULL_DISABLED

func _load_manifest() -> void:
    var path := "%s/manifest.json" % data_root
    if not FileAccess.file_exists(path):
        push_error("National road manifest missing: " + path)
        return
    var payload = JSON.parse_string(FileAccess.get_file_as_string(path))
    if not payload is Dictionary:
        push_error("Invalid Jamaica road manifest")
        return
    manifest = payload
    tile_size = float(manifest.get("tile_size", tile_size))
    if tile_size <= 0.0:
        push_error("Invalid national tile size")
        return
    coordinates.configure(manifest)
    graph.configure(data_root + "/graph", manifest.get("graph", {}))
    for item in manifest.get("tiles", []):
        _tile_files[_tile_key(int(item.x), int(item.z))] = str(item.file)
    var stats: Dictionary = manifest.get("stats", {})
    print("Yardman Jamaica roads: %s roads / %s tiles / %s persistent graph edges" %
        [str(stats.get("road_features", "?")), str(stats.get("tiles", "?")), str(stats.get("graph_edges", "?"))])

func _tile_key(tx: int, tz: int) -> String:
    return "%d:%d" % [tx, tz]

func _key_tile(key: String) -> Vector2i:
    var parts := key.split(":")
    return Vector2i(int(parts[0]), int(parts[1]))

func _target_tile() -> Vector2i:
    if target == null:
        return Vector2i.ZERO
    var world: PackedFloat64Array = coordinates.local_to_world(target.global_position)
    return coordinates.tile_for(world[0], world[2])

func _refresh_tiles(force: bool) -> void:
    if target == null or _tile_files.is_empty():
        return
    var current := _target_tile()
    if not force and current == _last_tile and load_radius == _last_radius:
        return
    generation += 1
    _last_tile = current
    _last_radius = load_radius
    _wanted.clear()
    _queue.clear()
    for dz in range(-load_radius, load_radius + 1):
        for dx in range(-load_radius, load_radius + 1):
            var key := _tile_key(current.x + dx, current.y + dz)
            if _tile_files.has(key):
                _wanted[key] = true
                if not _loaded.has(key) and not _jobs.has(key) and str(_building.get("key", "")) != key and not _failed.has(key):
                    _queue.append(key)
    _queue.sort_custom(func(a: String, b: String) -> bool:
        return _key_tile(a).distance_squared_to(current) < _key_tile(b).distance_squared_to(current))
    # Retain an extra ring to prevent load/unload oscillation at a boundary.
    for key in _loaded.keys():
        var tile := _key_tile(str(key))
        if maxi(absi(tile.x - current.x), absi(tile.y - current.y)) > load_radius + 1:
            _loaded[key].queue_free()
            _loaded.erase(key)
            tile_removed.emit(tile)
    if not _building.is_empty() and not _wanted.has(_building.key):
        _building.root.free()
        _building.clear()

func _start_jobs() -> void:
    while _jobs.size() < max_io_jobs and not _queue.is_empty():
        var key: String = _queue.pop_front()
        if not _wanted.has(key):
            continue
        var path := "%s/%s" % [data_root, str(_tile_files[key])]
        var thread := Thread.new()
        var error := thread.start(_read_tile.bind(path))
        if error != OK:
            _failed[key] = true
            push_error("Cannot start road tile reader: " + key)
            continue
        _jobs[key] = {"thread": thread, "generation": generation}

static func _read_tile(path: String) -> Dictionary:
    if not FileAccess.file_exists(path):
        return {"error": "Missing road tile: " + path}
    var payload = JSON.parse_string(FileAccess.get_file_as_string(path))
    if not payload is Dictionary or not payload.get("segments", null) is Array:
        return {"error": "Invalid road tile: " + path}
    return payload

func _poll_jobs() -> void:
    for key in _jobs.keys():
        var thread: Thread = _jobs[key].thread
        if thread.is_alive():
            continue
        if not _wanted.has(key):
            thread.wait_to_finish()
            _jobs.erase(key)
            continue
        if not _building.is_empty():
            continue
        var payload: Dictionary = thread.wait_to_finish()
        _jobs.erase(key)
        if payload.has("error"):
            _failed[key] = true
            push_error(str(payload.error))
            continue
        var tile := _key_tile(str(key))
        var tile_root := Node3D.new()
        tile_root.name = "RoadTile_%d_%d" % [tile.x, tile.y]
        tile_root.position = coordinates.world_to_local(float(tile.x) * tile_size, float(tile.y) * tile_size)
        _building = {"key": key, "tile": tile, "root": tile_root,
            "segments": payload.segments, "cursor": 0, "batch": 0,
            "paved_vertices": PackedVector3Array(), "paved_indices": PackedInt32Array(),
            "dirt_vertices": PackedVector3Array(), "dirt_indices": PackedInt32Array()}

func _prepare_geometry() -> void:
    if _building.is_empty():
        return
    var start := Time.get_ticks_usec()
    var processed := 0
    var segments: Array = _building.segments
    while _building.cursor < segments.size() and processed < max_segments_per_frame:
        var segment = segments[_building.cursor]
        _building.cursor += 1
        processed += 1
        if segment is Array and segment.size() >= 7:
            var dirt := (int(segment[6]) & 8) != 0
            _append_segment(_building.dirt_vertices if dirt else _building.paved_vertices,
                _building.dirt_indices if dirt else _building.paved_indices, segment, _building.tile)
        if _building.cursor % 2048 == 0:
            _flush_mesh_batch()
        if Time.get_ticks_usec() - start >= geometry_budget_us:
            break
    if _building.cursor >= segments.size():
        _flush_mesh_batch()
        var tile_root: Node3D = _building.root
        var key: String = _building.key
        var tile: Vector2i = _building.tile
        add_child(tile_root)
        _loaded[key] = tile_root
        _building.clear()
        tile_ready.emit(tile)
        tile_content_ready.emit(tile, tile_root, segments)

func _append_segment(vertices: PackedVector3Array, indices: PackedInt32Array, segment: Array, tile: Vector2i) -> void:
    var origin_x := float(tile.x) * tile_size
    var origin_z := float(tile.y) * tile_size
    var polygon: Array = []
    if segment.size() >= 12:
        polygon = segment[11]
    else:
        var d := Vector2(float(segment[2]) - float(segment[0]), float(segment[3]) - float(segment[1]))
        if d.length_squared() < 0.0001:
            return
        var n := Vector2(-d.y, d.x).normalized() * float(segment[4]) * 0.5
        polygon = [[float(segment[0]) + n.x, 0.0, float(segment[1]) + n.y],
            [float(segment[0]) - n.x, 0.0, float(segment[1]) - n.y],
            [float(segment[2]) - n.x, 0.0, float(segment[3]) - n.y],
            [float(segment[2]) + n.x, 0.0, float(segment[3]) + n.y]]
    var base := vertices.size()
    for p in polygon:
        vertices.append(Vector3(float(p[0]) - origin_x, float(p[1]) + 0.08, float(p[2]) - origin_z))
    for i in range(1, polygon.size() - 1):
        # Ribbons are counterclockwise in X/Z. Reverse for Godot's upward
        # facing front side rather than relying on double-sided backfaces.
        indices.append_array(PackedInt32Array([base, base + i + 1, base + i]))

func _flush_mesh_batch() -> void:
    _add_surface_mesh(_building.root, _building.paved_vertices, _building.paved_indices, _asphalt_material, "Paved")
    _add_surface_mesh(_building.root, _building.dirt_vertices, _building.dirt_indices, _dirt_material, "Unpaved")
    _building.paved_vertices = PackedVector3Array()
    _building.paved_indices = PackedInt32Array()
    _building.dirt_vertices = PackedVector3Array()
    _building.dirt_indices = PackedInt32Array()
    _building.batch += 1

func _add_surface_mesh(parent: Node3D, vertices: PackedVector3Array, indices: PackedInt32Array, material: Material, label: String) -> void:
    if vertices.is_empty():
        return
    var normals := PackedVector3Array()
    normals.resize(vertices.size())
    normals.fill(Vector3.UP)
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = normals
    arrays[Mesh.ARRAY_INDEX] = indices
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    mesh.surface_set_material(0, material)
    var instance := MeshInstance3D.new()
    instance.name = label
    instance.mesh = mesh
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    parent.add_child(instance)

func is_tile_ready(tile: Vector2i) -> bool:
    return _loaded.has(_tile_key(tile.x, tile.y))

func has_tile(tile: Vector2i) -> bool:
    return _tile_files.has(_tile_key(tile.x, tile.y))

func is_world_position_ready(x: float, z: float) -> bool:
    return is_tile_ready(coordinates.tile_for(x, z))

func queued_count() -> int:
    return _queue.size() + (0 if _building.is_empty() else 1)

func inflight_count() -> int:
    return _jobs.size()

func world_to_local(x: float, z: float, y: float = 0.0) -> Vector3:
    return coordinates.world_to_local(x, z, y)

func local_to_world(local: Vector3) -> PackedFloat64Array:
    return coordinates.local_to_world(local)

func rebase_origin(x: float, z: float, y: float = 0.0) -> Vector3:
    var shift: Vector3 = coordinates.rebase(x, z, y)
    for tile_root in _loaded.values():
        tile_root.position += shift
    if not _building.is_empty():
        _building.root.position += shift
    return shift
