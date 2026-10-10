extends Node3D
class_name JamaicaBuildingStreamer

signal cell_ready(cell: Vector2i, building_count: int)
signal cell_removed(cell: Vector2i)
const BuildingShader = preload("res://shaders/building_surface.gdshader")
const MAX_CELL_BYTES := 32 * 1024 * 1024
const PALETTE := [Color(0.78, 0.73, 0.59), Color(0.67, 0.72, 0.66), Color(0.72, 0.48, 0.38), Color(0.64, 0.72, 0.78), Color(0.87, 0.83, 0.71), Color(0.54, 0.64, 0.51)]

var target: Node3D
var coordinates
var terrain
var data_root := "res://data/buildings"
var cell_size := 256.0
var tile_size := 4096.0
var quality := "Balanced":
    set(value):
        quality = value
        match value:
            "Performance":
                draw_distance = 450.0
                max_loaded_cells = 64
            "Quality":
                draw_distance = 1100.0
                max_loaded_cells = 144
            "Ultra":
                draw_distance = 1450.0
                max_loaded_cells = 192
            _:
                draw_distance = 800.0
                max_loaded_cells = 96
        _last_cell = Vector2i(999999, 999999)
var draw_distance := 800.0:
    set(value):
        draw_distance = clampf(value, 256.0, 1800.0)
        for material in [_wall_material, _roof_material]:
            if material != null:
                material.set_shader_parameter("visibility_distance", draw_distance)
        _last_cell = Vector2i(999999, 999999)
var collision_distance := 180.0
var max_loaded_cells := 96
var max_io_jobs := 2
var max_buildings_per_frame := 20
var geometry_budget_us := 1800
var max_cell_vertices := 400000
var manifest: Dictionary = {}
var generation := 0
var _tile_files: Dictionary = {}
var _tile_cells: Dictionary = {}
var _wanted: Dictionary = {}
var _loaded: Dictionary = {}
var _jobs: Dictionary = {}
var _failed: Dictionary = {}
var _queue: Array[String] = []
var _build: Dictionary = {}
var _last_cell := Vector2i(999999, 999999)
var _world_position := Vector2.ZERO
var _refresh_clock := 0.0
var _wall_material: ShaderMaterial
var _roof_material: ShaderMaterial

func configure(root: String, world_coordinates, world_terrain = null) -> void:
    data_root = root
    coordinates = world_coordinates
    terrain = world_terrain
    if is_node_ready():
        _load_manifest()

func _ready() -> void:
    _wall_material = ShaderMaterial.new()
    _wall_material.shader = BuildingShader
    _wall_material.set_shader_parameter("visibility_distance", draw_distance)
    _roof_material = ShaderMaterial.new()
    _roof_material.shader = BuildingShader
    _roof_material.set_shader_parameter("roof_surface", true)
    _roof_material.set_shader_parameter("visibility_distance", draw_distance)
    _load_manifest()

func _load_manifest() -> void:
    if coordinates == null:
        return
    var path := data_root + "/manifest.json"
    if not FileAccess.file_exists(path):
        push_warning("Building manifest unavailable: " + path)
        return
    var result: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
    if not result is Dictionary or int(result.get("format", 0)) != 1:
        push_error("Invalid building manifest")
        return
    if str(result.get("crs", "")) != "EPSG:3448":
        push_error("Building CRS differs from world coordinates")
        return
    var origin: Dictionary = result.get("origin", {})
    if absf(float(origin.get("easting", 0.0)) - coordinates.projected_origin_easting) > 0.001 or absf(float(origin.get("northing", 0.0)) - coordinates.projected_origin_northing) > 0.001:
        push_error("Building origin differs from registered world")
        return
    manifest = result
    cell_size = float(manifest.cell_size)
    tile_size = float(manifest.tile_size)
    if cell_size != 256.0 or tile_size != 4096.0:
        push_error("Unsupported building content grid")
        manifest.clear()
        return
    _tile_files.clear()
    _tile_cells.clear()
    for entry in manifest.get("tiles", []):
        var tile := Vector2i(int(entry.x), int(entry.z))
        var tile_key := _key(tile)
        _tile_files[tile_key] = str(entry.file)
        var cells: Dictionary = {}
        for cell in entry.get("cells", []):
            cells[_key(Vector2i(int(cell[0]), int(cell[1])))] = true
        _tile_cells[tile_key] = cells
    print("Yardman buildings: %s source footprints / %s streamed cells" % [str(manifest.get("stats", {}).get("buildings", "?")), str(manifest.get("stats", {}).get("cells", "?"))])

func _process(delta: float) -> void:
    _refresh_clock += delta
    if target != null and coordinates != null and _refresh_clock >= 0.2:
        _refresh_clock = 0.0
        var world: PackedFloat64Array = coordinates.local_to_world(target.global_position)
        update_world(world[0], world[2])
    _poll_jobs()
    _prepare_geometry()
    _start_jobs()
    _refresh_collision()

func _exit_tree() -> void:
    for job in _jobs.values():
        var thread: Thread = job.thread
        if thread.is_started():
            thread.wait_to_finish()
    _jobs.clear()
    if not _build.is_empty():
        _build.root.free()
        _build.clear()

func _key(cell: Vector2i) -> String:
    return "%d:%d" % [cell.x, cell.y]

func _cell(key: String) -> Vector2i:
    var pieces := key.split(":")
    return Vector2i(int(pieces[0]), int(pieces[1]))

func _address(cell: Vector2i) -> Dictionary:
    var tile := Vector2i(floori(float(cell.x) / 16.0), floori(float(cell.y) / 16.0))
    return {"tile": tile, "local": Vector2i(posmod(cell.x, 16), posmod(cell.y, 16))}

func _has_cell(cell: Vector2i) -> bool:
    var address := _address(cell)
    var tile_key := _key(address.tile)
    return _tile_cells.get(tile_key, {}).has(_key(address.local))

func update_world(x: float, z: float, force := false) -> void:
    if manifest.is_empty() or not is_finite(x) or not is_finite(z):
        return
    _world_position = Vector2(x, z)
    var current := Vector2i(floori(x / cell_size), floori(z / cell_size))
    if not force and current == _last_cell:
        return
    generation += 1
    _last_cell = current
    var radius := ceili((draw_distance + cell_size) / cell_size)
    var candidates: Array[String] = []
    for dz in range(-radius, radius + 1):
        for dx in range(-radius, radius + 1):
            var candidate := current + Vector2i(dx, dz)
            var center := (Vector2(candidate) + Vector2.ONE * 0.5) * cell_size
            if center.distance_to(_world_position) <= draw_distance + cell_size and _has_cell(candidate):
                candidates.append(_key(candidate))
    candidates.sort_custom(func(a: String, b: String) -> bool: return _cell(a).distance_squared_to(current) < _cell(b).distance_squared_to(current))
    if candidates.size() > max_loaded_cells:
        candidates.resize(max_loaded_cells)
    _wanted.clear()
    _queue.clear()
    for key in candidates:
        _wanted[key] = true
        if not _loaded.has(key) and not _jobs.has(key) and str(_build.get("key", "")) != key and not _failed.has(key):
            _queue.append(key)
    for key in _loaded.keys():
        if not _wanted.has(key):
            _loaded[key].root.queue_free()
            _loaded.erase(key)
            cell_removed.emit(_cell(str(key)))
    for key in _failed.keys():
        if not _wanted.has(key):
            _failed.erase(key)
    if not _build.is_empty() and not _wanted.has(_build.key):
        _build.root.free()
        _build.clear()

static func _read_cell(path: String, local_cell: Vector2i) -> Dictionary:
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        return {"error": "Missing building tile " + path}
    if file.get_buffer(4).get_string_from_ascii() != "YMB1":
        return {"error": "Invalid building pack header"}
    var count := int(file.get_32())
    if count < 0 or count > 256 or file.get_length() < 8 + count * 12:
        return {"error": "Invalid building cell index count"}
    for index in range(count):
        var cx := int(file.get_16())
        var cz := int(file.get_16())
        var offset := int(file.get_32())
        var length := int(file.get_32())
        if offset < 8 + count * 12 or offset + length > file.get_length() or length > 8 * 1024 * 1024:
            return {"error": "Invalid building cell index bounds"}
        if cx == local_cell.x and cz == local_cell.y:
            file.seek(offset)
            var compressed := file.get_buffer(length)
            var bytes := compressed.decompress_dynamic(MAX_CELL_BYTES, FileAccess.COMPRESSION_GZIP)
            if bytes.is_empty():
                return {"error": "Building cell decompression failed"}
            var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
            if not parsed is Array or parsed.size() > 20000:
                return {"error": "Invalid or oversized building cell payload"}
            return {"records": parsed}
    return {"records": []}

func _start_jobs() -> void:
    while _jobs.size() < max_io_jobs and not _queue.is_empty():
        var key: String = _queue.pop_front()
        if not _wanted.has(key):
            continue
        var address := _address(_cell(key))
        var path := data_root + "/" + str(_tile_files[_key(address.tile)])
        var thread := Thread.new()
        if thread.start(_read_cell.bind(path, address.local)) != OK:
            _failed[key] = true
            push_error("Cannot start building cell reader")
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
        if not _build.is_empty():
            continue
        var result: Dictionary = thread.wait_to_finish()
        _jobs.erase(key)
        if result.has("error"):
            _failed[key] = true
            push_error(str(result.error))
            continue
        var cell := _cell(str(key))
        var cell_root := Node3D.new()
        cell_root.name = "Buildings_%d_%d" % [cell.x, cell.y]
        cell_root.position = coordinates.world_to_local(float(cell.x) * cell_size, float(cell.y) * cell_size)
        _build = {"key": key, "cell": cell, "root": cell_root, "records": result.records, "cursor": 0,
            "wall_vertices": PackedVector3Array(), "wall_normals": PackedVector3Array(), "wall_uvs": PackedVector2Array(), "wall_colors": PackedColorArray(), "wall_indices": PackedInt32Array(),
            "roof_vertices": PackedVector3Array(), "roof_normals": PackedVector3Array(), "roof_uvs": PackedVector2Array(), "roof_colors": PackedColorArray(), "roof_indices": PackedInt32Array()}

func _prepare_geometry() -> void:
    if _build.is_empty():
        return
    var started := Time.get_ticks_usec()
    for index in range(max_buildings_per_frame):
        if _build.cursor >= _build.records.size():
            _complete_cell()
            return
        var record: Variant = _build.records[_build.cursor]
        if not _append_building(record):
            _failed[_build.key] = true
            push_error("Invalid building record in cell " + str(_build.key))
            _build.root.free()
            _build.clear()
            return
        _build.cursor += 1
        if _build.wall_vertices.size() + _build.roof_vertices.size() > max_cell_vertices:
            _failed[_build.key] = true
            push_error("Building mesh exceeded cell geometry bound")
            _build.root.free()
            _build.clear()
            return
        if Time.get_ticks_usec() - started >= geometry_budget_us:
            break

func _append_building(record: Variant) -> bool:
    if not record is Array or record.size() != 8 or not record[5] is Array or not record[6] is Array or not record[7] is Array or not is_finite(float(record[4])):
        return false
    var identifier := str(record[0])
    var variant := absi(identifier.hash()) % PALETTE.size()
    var color: Color = PALETTE[variant]
    var roof_color := Color(0.43, 0.45, 0.43).lerp(Color(0.61, 0.33, 0.24), float(variant % 3) * 0.28)
    var roof_y := float(record[4])
    var ring_index := 0
    for ring in record[5]:
        if not ring is Array or ring.size() < 3:
            return false
        var signed_area := 0.0
        for index in range(ring.size()):
            var current: Variant = ring[index]
            var next: Variant = ring[(index + 1) % ring.size()]
            if not current is Array or current.size() != 3 or not next is Array or next.size() != 3:
                return false
            signed_area += float(current[0]) * float(next[2]) - float(next[0]) * float(current[2])
        var normal_sign := 1.0 if (signed_area > 0.0) == (ring_index == 0) else -1.0
        var station := 0.0
        for index in range(ring.size()):
            var before: Variant = ring[index]
            var after: Variant = ring[(index + 1) % ring.size()]
            if not before is Array or before.size() != 3 or not after is Array or after.size() != 3:
                return false
            var a := Vector3(float(before[0]), float(before[1]), float(before[2]))
            var b := Vector3(float(after[0]), float(after[1]), float(after[2]))
            if not a.is_finite() or not b.is_finite():
                return false
            var length := Vector2(b.x - a.x, b.z - a.z).length()
            if length < 0.0001:
                continue
            var normal := Vector3(b.z - a.z, 0.0, a.x - b.x).normalized() * normal_sign
            var offset: int = _build.wall_vertices.size()
            _build.wall_vertices.append_array(PackedVector3Array([a, Vector3(a.x, roof_y, a.z), b, Vector3(b.x, roof_y, b.z)]))
            for vertex in range(4):
                _build.wall_normals.append(normal)
                _build.wall_colors.append(color)
            _build.wall_uvs.append_array(PackedVector2Array([Vector2(station, a.y - roof_y), Vector2(station, 0.0), Vector2(station + length, b.y - roof_y), Vector2(station + length, 0.0)]))
            _build.wall_indices.append_array(PackedInt32Array([offset, offset + 1, offset + 2, offset + 2, offset + 1, offset + 3]))
            station += length
        ring_index += 1
    var roof_offset: int = _build.roof_vertices.size()
    for point in record[6]:
        if not point is Array or point.size() != 2 or not is_finite(float(point[0])) or not is_finite(float(point[1])):
            return false
        _build.roof_vertices.append(Vector3(float(point[0]), roof_y, float(point[1])))
        _build.roof_normals.append(Vector3.UP)
        _build.roof_uvs.append(Vector2(float(point[0]), float(point[1])))
        _build.roof_colors.append(roof_color)
    if record[7].size() % 3 != 0:
        return false
    for value in record[7]:
        var index := int(value)
        if index < 0 or index >= record[6].size():
            return false
        _build.roof_indices.append(roof_offset + index)
    return true

func _make_mesh(kind: String, material: ShaderMaterial) -> ArrayMesh:
    var mesh := ArrayMesh.new()
    var indices: PackedInt32Array = _build[kind + "_indices"]
    if indices.is_empty():
        return mesh
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = _build[kind + "_vertices"]
    arrays[Mesh.ARRAY_NORMAL] = _build[kind + "_normals"]
    arrays[Mesh.ARRAY_TEX_UV] = _build[kind + "_uvs"]
    arrays[Mesh.ARRAY_COLOR] = _build[kind + "_colors"]
    arrays[Mesh.ARRAY_INDEX] = indices
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    mesh.surface_set_material(0, material)
    return mesh

func _complete_cell() -> void:
    var cell_root: Node3D = _build.root
    var meshes: Array[ArrayMesh] = []
    for kind in ["wall", "roof"]:
        var material := _wall_material if kind == "wall" else _roof_material
        var mesh := _make_mesh(kind, material)
        if mesh.get_surface_count() == 0:
            continue
        var instance := MeshInstance3D.new()
        instance.name = "Walls" if kind == "wall" else "Roofs"
        instance.mesh = mesh
        instance.visibility_range_end = draw_distance + cell_size
        instance.visibility_range_end_margin = 96.0
        cell_root.add_child(instance)
        meshes.append(mesh)
    var body := StaticBody3D.new()
    body.name = "NearCollision"
    body.collision_layer = 0
    body.collision_mask = 0
    var collider := CollisionShape3D.new()
    body.add_child(collider)
    cell_root.add_child(body)
    add_child(cell_root)
    var cell: Vector2i = _build.cell
    var count: int = _build.records.size()
    _loaded[_build.key] = {"root": cell_root, "body": body, "collider": collider, "meshes": meshes, "count": count}
    _build.clear()
    _refresh_collision()
    cell_ready.emit(cell, count)

func _refresh_collision() -> void:
    var created := false
    for key in _loaded:
        var cell := _cell(str(key))
        var center := (Vector2(cell) + Vector2.ONE * 0.5) * cell_size
        var active := center.distance_to(_world_position) <= collision_distance + cell_size * 0.71
        var body: StaticBody3D = _loaded[key].body
        var collider: CollisionShape3D = _loaded[key].collider
        if not active:
            body.collision_layer = 0
            collider.shape = null
        elif collider.shape == null and not created:
            # A distant visible cell does not retain a physics BVH. Prepare
            # one nearby merged collider per pass, then discard it on retreat.
            var faces := PackedVector3Array()
            for mesh in _loaded[key].meshes:
                faces.append_array(mesh.get_faces())
            if not faces.is_empty():
                var shape := ConcavePolygonShape3D.new()
                shape.backface_collision = true
                shape.set_faces(faces)
                collider.shape = shape
                body.collision_layer = 1
            created = true
        elif collider.shape != null:
            body.collision_layer = 1

func rebase_by(shift: Vector3) -> void:
    for entry in _loaded.values():
        entry.root.position += shift
    if not _build.is_empty():
        _build.root.position += shift

func is_idle() -> bool:
    return inflight_count() == 0

func inflight_count() -> int:
    var pending := _queue.size() + _jobs.size() + (0 if _build.is_empty() else 1)
    for key in _loaded:
        var cell := _cell(str(key))
        var center := (Vector2(cell) + Vector2.ONE * 0.5) * cell_size
        var collider: CollisionShape3D = _loaded[key].collider
        if collider.shape == null and not _loaded[key].meshes.is_empty() and center.distance_to(_world_position) <= collision_distance + cell_size * 0.71:
            pending += 1
    return pending
