extends "res://scripts/road_streamer.gd"
class_name JamaicaTerrainStreamer

var resolution := 65
var spacing := 64.0
var _height_data: Dictionary = {}
var _terrain_material: StandardMaterial3D
var _far_thread: Thread
var _far_build: Dictionary = {}
var _far_root: MeshInstance3D
var _overview_heights := PackedFloat32Array()
var _far_tile := Vector2i(999999, 999999)

func _ready() -> void:
    super._ready()
    tile_removed.connect(func(tile: Vector2i) -> void: _height_data.erase(_tile_key(tile.x, tile.y)))
    var path := data_root + "/" + str(manifest.get("overview", {}).get("file", "overview.bin"))
    _far_thread = Thread.new()
    if _far_thread.start(_read_height.bind(path)) != OK:
        push_error("Cannot start terrain overview reader")

func _exit_tree() -> void:
    if _far_thread != null and _far_thread.is_started():
        _far_thread.wait_to_finish()
    super._exit_tree()

func _process(delta: float) -> void:
    super._process(delta)
    if _far_tile != _last_tile and not _overview_heights.is_empty():
        _start_far_build()
    _prepare_far()

func _make_materials() -> void:
    _terrain_material = StandardMaterial3D.new()
    _terrain_material.vertex_color_use_as_albedo = true
    _terrain_material.roughness = 0.98
    _terrain_material.cull_mode = BaseMaterial3D.CULL_DISABLED

func _load_manifest() -> void:
    var payload = JSON.parse_string(FileAccess.get_file_as_string(data_root + "/manifest.json"))
    if not payload is Dictionary:
        push_error("Missing or invalid national terrain manifest")
        return
    manifest = payload
    tile_size = float(manifest.tile_size)
    resolution = int(manifest.resolution)
    spacing = float(manifest.sample_spacing_m)
    coordinates.configure(manifest)
    for item in manifest.tiles:
        _tile_files[_tile_key(int(item.x), int(item.z))] = str(item.file)
    print("Yardman terrain: %d cells, peak %.1f real metres" % [manifest.tiles.size(), float(manifest.max_height)])

static func _read_height(path: String) -> Dictionary:
    if not FileAccess.file_exists(path):
        return {"error": "Missing terrain samples: " + path}
    var bytes := FileAccess.get_file_as_bytes(path)
    if bytes.is_empty() or bytes.size() % 4 != 0:
        return {"error": "Invalid terrain samples: " + path}
    return {"heights": bytes.to_float32_array()}

func _start_jobs() -> void:
    while _jobs.size() < max_io_jobs and not _queue.is_empty():
        var key: String = _queue.pop_front()
        if not _wanted.has(key):
            continue
        var thread := Thread.new()
        var error := thread.start(_read_height.bind("%s/%s" % [data_root, _tile_files[key]]))
        if error != OK:
            _failed[key] = true
            push_error("Cannot start terrain reader")
            continue
        _jobs[key] = {"thread": thread, "generation": generation}

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
        if payload.has("error") or payload.get("heights", []).size() != resolution * resolution:
            _failed[key] = true
            push_error(str(payload.get("error", "Wrong terrain sample count")))
            continue
        var tile := _key_tile(str(key))
        var tile_root := Node3D.new()
        tile_root.name = "TerrainTile_%d_%d" % [tile.x, tile.y]
        tile_root.position = coordinates.world_to_local(float(tile.x) * tile_size, float(tile.y) * tile_size)
        _building = {"key": key, "tile": tile, "root": tile_root, "heights": payload.heights, "cursor": 0,
            "vertices": PackedVector3Array(), "indices": PackedInt32Array(),
            "normals": PackedVector3Array(), "colors": PackedColorArray()}

func _prepare_geometry() -> void:
    if _building.is_empty():
        return
    var start := Time.get_ticks_usec()
    for row in range(4):
        var z: int = _building.cursor
        if z >= resolution:
            _complete_near()
            return
        _append_height_row(_building, z, resolution, resolution, spacing, 0.0, 0.0, false)
        _building.cursor += 1
        if Time.get_ticks_usec() - start >= geometry_budget_us:
            break

func _height_color(height: float, slope: float) -> Color:
    if height < 2.0:
        return Color(0.38, 0.43, 0.25)
    var low := Color(0.24, 0.38, 0.14)
    var high := Color(0.12, 0.26, 0.18)
    var color := low.lerp(high, clampf(height / 1800.0, 0.0, 1.0))
    return color.lerp(Color(0.48, 0.43, 0.34), clampf((slope - 0.45) * 0.8, 0.0, 0.65))

func _append_height_row(job: Dictionary, z: int, width: int, depth: int, step: float, ox: float, oz: float, far: bool) -> void:
    var heights: PackedFloat32Array = job.heights
    for x in range(width):
        var y := float(heights[z * width + x])
        var dx := (float(heights[z * width + maxi(x - 1, 0)]) - float(heights[z * width + mini(x + 1, width - 1)])) / (2.0 * step)
        var dz := (float(heights[maxi(z - 1, 0) * width + x]) - float(heights[mini(z + 1, depth - 1) * width + x])) / (2.0 * step)
        job.vertices.append(Vector3(float(x) * step, y - (1.0 if far else 0.0), float(z) * step))
        job.normals.append(Vector3(dx, 1.0, dz).normalized())
        job.colors.append(_height_color(y, Vector2(dx, dz).length()))
        if x == width - 1 or z == depth - 1:
            continue
        var a := z * width + x
        var b := a + 1
        var c := a + width
        var d := c + 1
        if maxf(maxf(heights[a], heights[b]), maxf(heights[c], heights[d])) < 0.1:
            continue
        # The coarse national shell excludes the streamed interaction patch.
        if far:
            var center := coordinates.tile_for(ox + (float(x) + 0.5) * step, oz + (float(z) + 0.5) * step)
            if maxi(absi(center.x - _last_tile.x), absi(center.y - _last_tile.y)) <= load_radius:
                continue
        job.indices.append_array(PackedInt32Array([a, c, b, b, c, d]))

func _mesh(job: Dictionary) -> ArrayMesh:
    var mesh := ArrayMesh.new()
    if job.indices.is_empty():
        return mesh
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = job.vertices
    arrays[Mesh.ARRAY_NORMAL] = job.normals
    arrays[Mesh.ARRAY_COLOR] = job.colors
    arrays[Mesh.ARRAY_INDEX] = job.indices
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    mesh.surface_set_material(0, _terrain_material)
    return mesh

func _complete_near() -> void:
    var tile_root: Node3D = _building.root
    var mesh := _mesh(_building)
    var instance := MeshInstance3D.new()
    instance.mesh = mesh
    tile_root.add_child(instance)
    if not _building.indices.is_empty():
        var faces := PackedVector3Array()
        for index in _building.indices:
            faces.append(_building.vertices[index])
        var shape := ConcavePolygonShape3D.new()
        shape.backface_collision = true
        shape.set_faces(faces)
        var collider := CollisionShape3D.new()
        collider.shape = shape
        var body := StaticBody3D.new()
        body.add_child(collider)
        tile_root.add_child(body)
    var key: String = _building.key
    var tile: Vector2i = _building.tile
    _height_data[key] = _building.heights
    add_child(tile_root)
    _loaded[key] = tile_root
    _building.clear()
    tile_ready.emit(tile)

func height_at(x: float, z: float) -> float:
    var tile := coordinates.tile_for(x, z)
    var heights: PackedFloat32Array = _height_data.get(_tile_key(tile.x, tile.y), PackedFloat32Array())
    if heights.is_empty():
        return NAN
    var fx := (x - float(tile.x) * tile_size) / spacing
    var fz := (z - float(tile.y) * tile_size) / spacing
    var ix := mini(int(fx), resolution - 2)
    var iz := mini(int(fz), resolution - 2)
    var u := fx - float(ix)
    var v := fz - float(iz)
    var a := float(heights[iz * resolution + ix])
    var b := float(heights[iz * resolution + ix + 1])
    var c := float(heights[(iz + 1) * resolution + ix])
    var d := float(heights[(iz + 1) * resolution + ix + 1])
    if u + v <= 1.0:
        return a + (b - a) * u + (c - a) * v
    return d + (c - d) * (1.0 - u) + (b - d) * (1.0 - v)

func rebase_by(shift: Vector3) -> void:
    for tile_root in _loaded.values():
        tile_root.position += shift
    if not _building.is_empty():
        _building.root.position += shift
    if _far_root != null:
        _far_root.position += shift

func _prepare_far() -> void:
    if _far_thread != null and _far_thread.is_started() and not _far_thread.is_alive():
        var payload: Dictionary = _far_thread.wait_to_finish()
        _far_thread = null
        if payload.has("error"):
            push_error(str(payload.error))
            return
        _overview_heights = payload.heights
        _start_far_build()
    if _far_build.is_empty() or _loaded.is_empty():
        return
    var overview: Dictionary = manifest.overview
    var start := Time.get_ticks_usec()
    while _far_build.cursor < int(overview.depth):
        _append_height_row(_far_build, int(_far_build.cursor), int(overview.width), int(overview.depth),
            float(overview.spacing), float(overview.origin_x), float(overview.origin_z), true)
        _far_build.cursor += 1
        if Time.get_ticks_usec() - start >= geometry_budget_us:
            return
    if _far_root != null:
        _far_root.queue_free()
    _far_root = MeshInstance3D.new()
    _far_root.name = "IslandOverviewLOD"
    _far_root.mesh = _mesh(_far_build)
    _far_root.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    _far_root.position = coordinates.world_to_local(float(overview.origin_x), float(overview.origin_z))
    add_child(_far_root)
    _far_build.clear()

func _start_far_build() -> void:
    _far_tile = _last_tile
    _far_build = {"heights": _overview_heights, "cursor": 0, "vertices": PackedVector3Array(),
        "indices": PackedInt32Array(), "normals": PackedVector3Array(), "colors": PackedColorArray()}
