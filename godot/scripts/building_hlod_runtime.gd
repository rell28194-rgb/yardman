extends Node3D
class_name YardmanBuildingHLODRuntime

# Cell-level distant building HLOD. The source building packs remain canonical:
# HLOD uses the registered outer footprint and source maximum roof height, while
# dropping courtyards, facade modules, texture families and inferred hip detail.
# Near cells continue to use JamaicaBuildingStreamer and its collision geometry.
const MAX_CELL_BYTES := 32 * 1024 * 1024
const MAX_HLOD_VERTICES_PER_CELL := 180000
const PALETTE := [
    Color(0.78, 0.73, 0.59),
    Color(0.67, 0.72, 0.66),
    Color(0.72, 0.48, 0.38),
    Color(0.64, 0.72, 0.78),
    Color(0.87, 0.83, 0.71),
    Color(0.54, 0.64, 0.51),
]

var _scene: Node
var _buildings: Node
var _coordinates
var _target: Node3D
var _data_root := "res://data/buildings"
var _manifest: Dictionary = {}
var _tile_files: Dictionary = {}
var _tile_cells: Dictionary = {}
var _loaded: Dictionary = {}
var _jobs: Dictionary = {}
var _failed: Dictionary = {}
var _queue: Array[String] = []
var _build: Dictionary = {}
var _world_position := Vector2.ZERO
var _last_cell := Vector2i(999999, 999999)
var _generation := 0
var _refresh_clock := 0.0
var _quality := "Balanced"
var _thermal_factor := 1.0
var _cell_size := 256.0
var _near_distance := 800.0
var _switch_distance := 496.0
var _far_distance := 2200.0
var _max_cells := 180
var _max_io_jobs := 1
var _max_buildings_per_frame := 64
var _geometry_budget_us := 1300
var _material: StandardMaterial3D
var _rust_spatial
var _spatial_cells: Array[Vector2i] = []
var _spatial_ready := false

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    add_to_group("yardman_render_quality")
    _material = StandardMaterial3D.new()
    _material.vertex_color_use_as_albedo = true
    _material.albedo_color = Color.WHITE
    _material.roughness = 0.96
    _material.metallic = 0.0

func _exit_tree() -> void:
    _release_scene()

func _process(delta: float) -> void:
    var current_scene := get_tree().current_scene
    if current_scene != _scene:
        _bind_scene(current_scene)
    if _buildings == null or not is_instance_valid(_buildings):
        return

    _refresh_clock += delta
    if _refresh_clock >= 0.35:
        _refresh_clock = 0.0
        _sync_from_streamer()
        _refresh_target_world()
        _apply_near_mesh_lod()
        _reposition_loaded()

    _poll_jobs()
    _prepare_build()
    _start_jobs()

func apply_render_policy(active: Dictionary) -> void:
    var next_quality := str(active.get("quality", _quality))
    var next_thermal := clampf(float(active.get("vegetation_factor", 1.0)), 0.25, 1.0)
    if next_quality == _quality and is_equal_approx(next_thermal, _thermal_factor):
        return
    _quality = next_quality
    _thermal_factor = next_thermal
    _apply_profile()
    _last_cell = Vector2i(999999, 999999)

static func profile_for_quality(quality: String, near_distance: float, thermal_factor: float) -> Dictionary:
    var base_far := 2200.0
    var base_cells := 180
    var base_io := 1
    var base_buildings := 64
    var base_budget_us := 1300
    match quality:
        "Performance":
            base_far = 1200.0
            base_cells = 96
            base_io = 1
            base_buildings = 40
            base_budget_us = 900
        "Quality":
            base_far = 3000.0
            base_cells = 280
            base_io = 2
            base_buildings = 80
            base_budget_us = 1600
        "Ultra":
            base_far = 3800.0
            base_cells = 380
            base_io = 2
            base_buildings = 96
            base_budget_us = 1900
        _:
            pass
    var thermal := clampf(thermal_factor, 0.25, 1.0)
    var distance_factor := lerpf(0.72, 1.0, thermal)
    var cell_factor := lerpf(0.55, 1.0, thermal)
    var safe_near := maxf(256.0, near_distance)
    var switch_distance := clampf(safe_near * 0.62, 280.0, maxf(280.0, safe_near - 64.0))
    var far_distance := maxf(safe_near + 512.0, base_far * distance_factor)
    return {
        "switch_distance": switch_distance,
        "far_distance": minf(far_distance, 4200.0),
        "max_cells": maxi(48, int(round(float(base_cells) * cell_factor))),
        "max_io_jobs": base_io if thermal >= 0.55 else 1,
        "max_buildings_per_frame": maxi(24, int(round(float(base_buildings) * lerpf(0.65, 1.0, thermal)))),
        "geometry_budget_us": maxi(700, int(round(float(base_budget_us) * lerpf(0.72, 1.0, thermal)))),
    }

func _apply_profile() -> void:
    var profile := profile_for_quality(_quality, _near_distance, _thermal_factor)
    _switch_distance = float(profile.switch_distance)
    _far_distance = float(profile.far_distance)
    _max_cells = int(profile.max_cells)
    _max_io_jobs = int(profile.max_io_jobs)
    _max_buildings_per_frame = int(profile.max_buildings_per_frame)
    _geometry_budget_us = int(profile.geometry_budget_us)
    for entry_value in _loaded.values():
        if not entry_value is Dictionary:
            continue
        var instance_value = entry_value.get("instance")
        if instance_value is MeshInstance3D:
            var instance := instance_value as MeshInstance3D
            instance.visibility_range_begin = _switch_distance
            instance.visibility_range_begin_margin = minf(96.0, _cell_size * 0.35)
            instance.visibility_range_end = _far_distance + _cell_size
            instance.visibility_range_end_margin = minf(128.0, _cell_size * 0.5)

func _bind_scene(scene: Node) -> void:
    _release_scene()
    _scene = scene
    if scene == null:
        return
    var buildings_value = scene.get("buildings")
    if not buildings_value is Node:
        return
    _buildings = buildings_value as Node
    _coordinates = _buildings.get("coordinates")
    var target_value = _buildings.get("target")
    if target_value is Node3D:
        _target = target_value as Node3D
    _data_root = str(_buildings.get("data_root"))
    if _data_root.is_empty() or _data_root == "<null>":
        _data_root = "res://data/buildings"
    var manifest_value = _buildings.get("manifest")
    if manifest_value is Dictionary and not (manifest_value as Dictionary).is_empty():
        _configure_manifest(manifest_value as Dictionary)
    else:
        _load_manifest()
    _sync_from_streamer()
    _last_cell = Vector2i(999999, 999999)

func _release_scene() -> void:
    if _buildings != null and is_instance_valid(_buildings):
        _restore_near_mesh_lod()
    for job_value in _jobs.values():
        if not job_value is Dictionary:
            continue
        var thread_value = job_value.get("thread")
        if thread_value is Thread:
            var thread := thread_value as Thread
            if thread.is_started():
                thread.wait_to_finish()
    _jobs.clear()
    _queue.clear()
    _failed.clear()
    _build.clear()
    for entry_value in _loaded.values():
        if entry_value is Dictionary:
            var root_value = entry_value.get("root")
            if root_value is Node and is_instance_valid(root_value):
                (root_value as Node).queue_free()
    _loaded.clear()
    _manifest.clear()
    _tile_files.clear()
    _tile_cells.clear()
    _rust_spatial = null
    _spatial_cells.clear()
    _spatial_ready = false
    set_meta("yardman_hlod_spatial_backend", "gdscript-grid")
    _scene = null
    _buildings = null
    _coordinates = null
    _target = null

func _load_manifest() -> void:
    var path := _data_root + "/manifest.json"
    if not FileAccess.file_exists(path):
        return
    var payload = JSON.parse_string(FileAccess.get_file_as_string(path))
    if payload is Dictionary:
        _configure_manifest(payload as Dictionary)

func _configure_manifest(payload: Dictionary) -> void:
    if float(payload.get("cell_size", 0.0)) <= 0.0:
        return
    _manifest = payload
    _cell_size = float(payload.get("cell_size", 256.0))
    _tile_files.clear()
    _tile_cells.clear()
    for entry_value in payload.get("tiles", []):
        if not entry_value is Dictionary:
            continue
        var entry := entry_value as Dictionary
        var tile := Vector2i(int(entry.get("x", 0)), int(entry.get("z", 0)))
        var tile_key := _key(tile)
        _tile_files[tile_key] = str(entry.get("file", ""))
        var cells: Dictionary = {}
        for cell_value in entry.get("cells", []):
            if cell_value is Array and (cell_value as Array).size() >= 2:
                var cell := cell_value as Array
                cells[_key(Vector2i(int(cell[0]), int(cell[1])))] = true
        _tile_cells[tile_key] = cells
    _rebuild_spatial_index()

func _rebuild_spatial_index() -> void:
    _rust_spatial = null
    _spatial_cells.clear()
    _spatial_ready = false
    set_meta("yardman_hlod_spatial_backend", "gdscript-grid")
    if not ClassDB.class_exists(&"YardmanRustKernels"):
        return

    var points := PackedVector2Array()
    var ids := PackedInt32Array()
    for tile_key_value in _tile_cells.keys():
        var tile := _cell(str(tile_key_value))
        var cells_value = _tile_cells.get(tile_key_value, {})
        if not cells_value is Dictionary:
            continue
        for local_key_value in (cells_value as Dictionary).keys():
            var local := _cell(str(local_key_value))
            var world_cell := tile * 16 + local
            var id := _spatial_cells.size()
            _spatial_cells.append(world_cell)
            points.append((Vector2(world_cell) + Vector2.ONE * 0.5) * _cell_size)
            ids.append(id)
    if points.is_empty():
        return

    var kernel = ClassDB.instantiate(&"YardmanRustKernels")
    if kernel == null:
        return
    if not bool(kernel.call("configure_spatial_index", points, ids)):
        return
    _rust_spatial = kernel
    _spatial_ready = true
    set_meta("yardman_hlod_spatial_backend", "rust-rstar")

func _sync_from_streamer() -> void:
    if _buildings == null:
        return
    _coordinates = _buildings.get("coordinates")
    var target_value = _buildings.get("target")
    if target_value is Node3D:
        _target = target_value as Node3D
    var quality_value := str(_buildings.get("quality"))
    var near_value := float(_buildings.get("draw_distance"))
    var changed := quality_value != _quality or not is_equal_approx(near_value, _near_distance)
    _quality = quality_value
    _near_distance = maxf(256.0, near_value)
    if changed:
        _apply_profile()
        _last_cell = Vector2i(999999, 999999)

func _refresh_target_world() -> void:
    if _coordinates == null or _target == null or not is_instance_valid(_target):
        return
    var world: PackedFloat64Array = _coordinates.local_to_world(_target.global_position)
    if world.size() < 3:
        return
    update_world(float(world[0]), float(world[2]))

func update_world(x: float, z: float, force := false) -> void:
    if _manifest.is_empty() or not is_finite(x) or not is_finite(z):
        return
    _world_position = Vector2(x, z)
    var current := Vector2i(floori(x / _cell_size), floori(z / _cell_size))
    if not force and current == _last_cell:
        return
    _generation += 1
    _last_cell = current
    var min_distance := maxf(0.0, _switch_distance - _cell_size * 0.85)
    var max_distance := _far_distance + _cell_size
    var candidates := _candidate_keys(current, min_distance, max_distance)
    if candidates.size() > _max_cells:
        candidates.resize(_max_cells)

    var wanted: Dictionary = {}
    var next_queue: Array[String] = []
    for key in candidates:
        wanted[key] = true
        if not _loaded.has(key) and not _jobs.has(key) and str(_build.get("key", "")) != key and not _failed.has(key):
            next_queue.append(key)
    _queue = next_queue

    for key_value in _loaded.keys():
        var key := str(key_value)
        if wanted.has(key):
            continue
        var entry = _loaded[key]
        if entry is Dictionary:
            var root_value = (entry as Dictionary).get("root")
            if root_value is Node:
                (root_value as Node).queue_free()
        _loaded.erase(key)
    for key_value in _failed.keys():
        if not wanted.has(str(key_value)):
            _failed.erase(key_value)
    if not _build.is_empty() and not wanted.has(str(_build.get("key", ""))):
        _build.clear()
    set_meta("yardman_hlod_wanted", wanted)

func _candidate_keys(current: Vector2i, min_distance: float, max_distance: float) -> Array[String]:
    if _spatial_ready and _rust_spatial != null and is_instance_valid(_rust_spatial):
        var ids_value = _rust_spatial.call(
            "query_spatial_annulus",
            _world_position,
            min_distance,
            max_distance,
            _spatial_cells.size()
        )
        if ids_value is PackedInt32Array:
            var candidates: Array[String] = []
            for id in ids_value as PackedInt32Array:
                if id >= 0 and id < _spatial_cells.size():
                    candidates.append(_key(_spatial_cells[id]))
            _sort_candidate_keys(candidates, current)
            return candidates
    return _candidate_keys_fallback(current, min_distance, max_distance)

func _candidate_keys_fallback(current: Vector2i, min_distance: float, max_distance: float) -> Array[String]:
    var radius := ceili(max_distance / _cell_size)
    var candidates: Array[String] = []
    for dz in range(-radius, radius + 1):
        for dx in range(-radius, radius + 1):
            var candidate := current + Vector2i(dx, dz)
            var center := (Vector2(candidate) + Vector2.ONE * 0.5) * _cell_size
            var distance := center.distance_to(_world_position)
            if distance >= min_distance and distance <= max_distance and _has_cell(candidate):
                candidates.append(_key(candidate))
    _sort_candidate_keys(candidates, current)
    return candidates

func _sort_candidate_keys(candidates: Array[String], current: Vector2i) -> void:
    candidates.sort_custom(func(a: String, b: String) -> bool:
        var distance_a := _cell(a).distance_squared_to(current)
        var distance_b := _cell(b).distance_squared_to(current)
        if distance_a == distance_b:
            return a < b
        return distance_a < distance_b)

func _wanted() -> Dictionary:
    var value = get_meta("yardman_hlod_wanted", {})
    return value if value is Dictionary else {}

func _key(cell: Vector2i) -> String:
    return "%d:%d" % [cell.x, cell.y]

func _cell(key: String) -> Vector2i:
    var pieces := key.split(":")
    if pieces.size() != 2:
        return Vector2i.ZERO
    return Vector2i(int(pieces[0]), int(pieces[1]))

func _address(cell: Vector2i) -> Dictionary:
    return {
        "tile": Vector2i(floori(float(cell.x) / 16.0), floori(float(cell.y) / 16.0)),
        "local": Vector2i(posmod(cell.x, 16), posmod(cell.y, 16)),
    }

func _has_cell(cell: Vector2i) -> bool:
    var address := _address(cell)
    var tile_key := _key(address.tile)
    var cells = _tile_cells.get(tile_key, {})
    return cells is Dictionary and (cells as Dictionary).has(_key(address.local))

static func _read_cell(path: String, local_cell: Vector2i) -> Dictionary:
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        return {"error": "Missing building HLOD tile " + path}
    if file.get_buffer(4).get_string_from_ascii() != "YMB1":
        return {"error": "Invalid building HLOD pack header"}
    var count := int(file.get_32())
    if count < 0 or count > 256 or file.get_length() < 8 + count * 12:
        return {"error": "Invalid building HLOD cell index count"}
    for index in range(count):
        var cx := int(file.get_16())
        var cz := int(file.get_16())
        var offset := int(file.get_32())
        var length := int(file.get_32())
        if offset < 8 + count * 12 or offset + length > file.get_length() or length > 8 * 1024 * 1024:
            return {"error": "Invalid building HLOD cell index bounds"}
        if cx == local_cell.x and cz == local_cell.y:
            file.seek(offset)
            var compressed := file.get_buffer(length)
            var bytes := compressed.decompress_dynamic(MAX_CELL_BYTES, FileAccess.COMPRESSION_GZIP)
            if bytes.is_empty():
                return {"error": "Building HLOD cell decompression failed"}
            var parsed = JSON.parse_string(bytes.get_string_from_utf8())
            if not parsed is Array or (parsed as Array).size() > 20000:
                return {"error": "Invalid or oversized building HLOD cell payload"}
            return {"records": parsed}
    return {"records": []}

func _start_jobs() -> void:
    var wanted := _wanted()
    while _jobs.size() < _max_io_jobs and not _queue.is_empty():
        var key: String = _queue.pop_front()
        if not wanted.has(key):
            continue
        var address := _address(_cell(key))
        var tile_key := _key(address.tile)
        if not _tile_files.has(tile_key):
            _failed[key] = true
            continue
        var relative := str(_tile_files[tile_key])
        if relative.is_empty():
            _failed[key] = true
            continue
        var thread := Thread.new()
        var path := _data_root + "/" + relative
        if thread.start(_read_cell.bind(path, address.local)) != OK:
            _failed[key] = true
            continue
        _jobs[key] = {"thread": thread, "generation": _generation}

func _poll_jobs() -> void:
    var wanted := _wanted()
    for key_value in _jobs.keys():
        var key := str(key_value)
        var job = _jobs[key]
        if not job is Dictionary:
            _jobs.erase(key)
            continue
        var thread_value = (job as Dictionary).get("thread")
        if not thread_value is Thread:
            _jobs.erase(key)
            continue
        var thread := thread_value as Thread
        if thread.is_alive():
            continue
        if not wanted.has(key):
            thread.wait_to_finish()
            _jobs.erase(key)
            continue
        if not _build.is_empty():
            continue
        var result = thread.wait_to_finish()
        _jobs.erase(key)
        if not result is Dictionary or (result as Dictionary).has("error"):
            _failed[key] = true
            continue
        var cell := _cell(key)
        _build = {
            "key": key,
            "cell": cell,
            "records": (result as Dictionary).get("records", []),
            "cursor": 0,
            "vertices": PackedVector3Array(),
            "normals": PackedVector3Array(),
            "colors": PackedColorArray(),
            "indices": PackedInt32Array(),
        }

func _prepare_build() -> void:
    if _build.is_empty():
        return
    var records = _build.get("records", [])
    if not records is Array:
        _failed[str(_build.get("key", ""))] = true
        _build.clear()
        return
    var started := Time.get_ticks_usec()
    for unused_index in range(_max_buildings_per_frame):
        var cursor := int(_build.get("cursor", 0))
        if cursor >= (records as Array).size():
            _complete_build()
            return
        var geometry := record_geometry((records as Array)[cursor])
        if not bool(geometry.get("valid", false)):
            _failed[str(_build.get("key", ""))] = true
            _build.clear()
            return
        _merge_geometry(geometry)
        _build.cursor = cursor + 1
        var vertices: PackedVector3Array = _build.vertices
        if vertices.size() > MAX_HLOD_VERTICES_PER_CELL:
            _failed[str(_build.get("key", ""))] = true
            _build.clear()
            return
        if Time.get_ticks_usec() - started >= _geometry_budget_us:
            break

static func record_geometry(record: Variant) -> Dictionary:
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var colors := PackedColorArray()
    var indices := PackedInt32Array()
    if not record is Array:
        return {"valid": false}
    var item := record as Array
    if item.size() != 8 or not item[5] is Array or not item[6] is Array or not item[7] is Array:
        return {"valid": false}
    var rings := item[5] as Array
    if rings.is_empty() or not rings[0] is Array or (rings[0] as Array).size() < 3:
        return {"valid": false}
    var outer := rings[0] as Array
    var roof_y := float(item[4])
    if not is_finite(roof_y):
        return {"valid": false}

    var identifier := str(item[0])
    var variant := absi(identifier.hash()) % PALETTE.size()
    var wall_color: Color = PALETTE[variant]
    var roof_color := Color(0.43, 0.45, 0.43).lerp(Color(0.61, 0.33, 0.24), float(variant % 3) * 0.28)
    var signed_area := 0.0
    for index in range(outer.size()):
        var p_value = outer[index]
        var q_value = outer[(index + 1) % outer.size()]
        if not p_value is Array or not q_value is Array:
            return {"valid": false}
        var p := p_value as Array
        var q := q_value as Array
        if p.size() != 3 or q.size() != 3:
            return {"valid": false}
        var a := Vector3(float(p[0]), float(p[1]), float(p[2]))
        var b := Vector3(float(q[0]), float(q[1]), float(q[2]))
        if not a.is_finite() or not b.is_finite() or roof_y < maxf(a.y, b.y):
            return {"valid": false}
        signed_area += a.x * b.z - b.x * a.z
    var normal_sign := 1.0 if signed_area > 0.0 else -1.0

    for index in range(outer.size()):
        var p := outer[index] as Array
        var q := outer[(index + 1) % outer.size()] as Array
        var a := Vector3(float(p[0]), float(p[1]), float(p[2]))
        var b := Vector3(float(q[0]), float(q[1]), float(q[2]))
        var horizontal := Vector2(b.x - a.x, b.z - a.z)
        if horizontal.length_squared() < 0.000001:
            continue
        var normal := Vector3(b.z - a.z, 0.0, a.x - b.x).normalized() * normal_sign
        var offset := vertices.size()
        vertices.append_array(PackedVector3Array([
            a,
            Vector3(a.x, roof_y, a.z),
            b,
            Vector3(b.x, roof_y, b.z),
        ]))
        for unused_vertex in range(4):
            normals.append(normal)
            colors.append(wall_color)
        indices.append_array(_clockwise_triangle(vertices, offset, offset + 1, offset + 2, normal))
        indices.append_array(_clockwise_triangle(vertices, offset + 2, offset + 1, offset + 3, normal))

    var roof_points := item[6] as Array
    var roof_indices := item[7] as Array
    var roof_offset := vertices.size()
    for point_value in roof_points:
        if not point_value is Array or (point_value as Array).size() != 2:
            return {"valid": false}
        var point := point_value as Array
        var x := float(point[0])
        var z := float(point[1])
        if not is_finite(x) or not is_finite(z):
            return {"valid": false}
        vertices.append(Vector3(x, roof_y, z))
        normals.append(Vector3.UP)
        colors.append(roof_color)
    if roof_indices.size() % 3 != 0:
        return {"valid": false}
    for triangle in range(0, roof_indices.size(), 3):
        var a_index := int(roof_indices[triangle])
        var b_index := int(roof_indices[triangle + 1])
        var c_index := int(roof_indices[triangle + 2])
        if a_index < 0 or b_index < 0 or c_index < 0 or a_index >= roof_points.size() or b_index >= roof_points.size() or c_index >= roof_points.size():
            return {"valid": false}
        indices.append_array(_clockwise_triangle(vertices, roof_offset + a_index, roof_offset + b_index, roof_offset + c_index, Vector3.UP))

    return {
        "valid": true,
        "vertices": vertices,
        "normals": normals,
        "colors": colors,
        "indices": indices,
    }

static func _clockwise_triangle(vertices: PackedVector3Array, a: int, b: int, c: int, normal: Vector3) -> PackedInt32Array:
    if (vertices[b] - vertices[a]).cross(vertices[c] - vertices[a]).dot(normal) > 0.0:
        return PackedInt32Array([a, c, b])
    return PackedInt32Array([a, b, c])

func _merge_geometry(geometry: Dictionary) -> void:
    var source_vertices: PackedVector3Array = geometry.vertices
    var source_normals: PackedVector3Array = geometry.normals
    var source_colors: PackedColorArray = geometry.colors
    var source_indices: PackedInt32Array = geometry.indices
    var vertices: PackedVector3Array = _build.vertices
    var normals: PackedVector3Array = _build.normals
    var colors: PackedColorArray = _build.colors
    var indices: PackedInt32Array = _build.indices
    var offset := vertices.size()
    vertices.append_array(source_vertices)
    normals.append_array(source_normals)
    colors.append_array(source_colors)
    for index in source_indices:
        indices.append(offset + index)
    _build.vertices = vertices
    _build.normals = normals
    _build.colors = colors
    _build.indices = indices

func _complete_build() -> void:
    var vertices: PackedVector3Array = _build.vertices
    var indices: PackedInt32Array = _build.indices
    var key := str(_build.get("key", ""))
    var cell: Vector2i = _build.get("cell", Vector2i.ZERO)
    var records = _build.get("records", [])
    if vertices.is_empty() or indices.is_empty():
        _build.clear()
        return
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = _build.normals
    arrays[Mesh.ARRAY_COLOR] = _build.colors
    arrays[Mesh.ARRAY_INDEX] = indices
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    mesh.surface_set_material(0, _material)

    var root := Node3D.new()
    root.name = "BuildingHLOD_%d_%d" % [cell.x, cell.y]
    root.position = _cell_local_position(cell)
    var instance := MeshInstance3D.new()
    instance.name = "MergedBuildingHLOD"
    instance.mesh = mesh
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    instance.visibility_range_begin = _switch_distance
    instance.visibility_range_begin_margin = minf(96.0, _cell_size * 0.35)
    instance.visibility_range_end = _far_distance + _cell_size
    instance.visibility_range_end_margin = minf(128.0, _cell_size * 0.5)
    root.add_child(instance)
    add_child(root)
    _loaded[key] = {
        "root": root,
        "instance": instance,
        "cell": cell,
        "count": (records as Array).size() if records is Array else 0,
        "vertices": vertices.size(),
    }
    _build.clear()

func _cell_local_position(cell: Vector2i) -> Vector3:
    if _coordinates == null:
        return Vector3(float(cell.x) * _cell_size, 0.0, float(cell.y) * _cell_size)
    return _coordinates.world_to_local(float(cell.x) * _cell_size, float(cell.y) * _cell_size)

func _reposition_loaded() -> void:
    if _coordinates == null:
        return
    for entry_value in _loaded.values():
        if not entry_value is Dictionary:
            continue
        var entry := entry_value as Dictionary
        var root_value = entry.get("root")
        var cell_value = entry.get("cell")
        if root_value is Node3D and cell_value is Vector2i:
            (root_value as Node3D).position = _cell_local_position(cell_value as Vector2i)

func _apply_near_mesh_lod() -> void:
    if _buildings == null:
        return
    var loaded_value = _buildings.get("_loaded")
    if not loaded_value is Dictionary:
        return
    var near_end := _switch_distance + minf(96.0, _cell_size * 0.375)
    for entry_value in (loaded_value as Dictionary).values():
        if not entry_value is Dictionary:
            continue
        var root_value = (entry_value as Dictionary).get("root")
        if not root_value is Node:
            continue
        var root := root_value as Node
        for child_name in ["Walls", "Roofs"]:
            var instance := root.get_node_or_null(child_name) as MeshInstance3D
            if instance == null:
                continue
            instance.visibility_range_end = near_end
            instance.visibility_range_end_margin = minf(64.0, _cell_size * 0.25)

func _restore_near_mesh_lod() -> void:
    if _buildings == null:
        return
    var loaded_value = _buildings.get("_loaded")
    if not loaded_value is Dictionary:
        return
    var full_end := maxf(256.0, float(_buildings.get("draw_distance"))) + _cell_size
    for entry_value in (loaded_value as Dictionary).values():
        if not entry_value is Dictionary:
            continue
        var root_value = (entry_value as Dictionary).get("root")
        if not root_value is Node:
            continue
        var root := root_value as Node
        for child_name in ["Walls", "Roofs"]:
            var instance := root.get_node_or_null(child_name) as MeshInstance3D
            if instance == null:
                continue
            instance.visibility_range_end = full_end
            instance.visibility_range_end_margin = 96.0

func is_idle() -> bool:
    return _queue.is_empty() and _jobs.is_empty() and _build.is_empty()

func runtime_snapshot() -> Dictionary:
    return {
        "quality": _quality,
        "thermal_factor": _thermal_factor,
        "near_distance": _near_distance,
        "switch_distance": _switch_distance,
        "far_distance": _far_distance,
        "max_cells": _max_cells,
        "loaded_cells": _loaded.size(),
        "queued_cells": _queue.size(),
        "io_jobs": _jobs.size(),
        "building_cell": not _build.is_empty(),
        "spatial_backend": str(get_meta("yardman_hlod_spatial_backend", "gdscript-grid")),
    }
