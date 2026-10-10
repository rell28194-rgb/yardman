extends "res://scripts/road_streamer.gd"
class_name JamaicaTerrainStreamer

const CoastGeometryScript = preload("res://scripts/coast_geometry.gd")
const CoastlineScript = preload("res://scripts/coastline.gd")
var resolution := 65
var spacing := 64.0
var coast_root := "res://data/coast"
var visuals: RefCounted
var coastline: Node3D
var _height_data: Dictionary = {}
var _coast_data: Dictionary = {}
var _terrain_material: Material
var _far_thread: Thread
var _far_build: Dictionary = {}
var _far_root: Node3D
var _far_sectors: Dictionary = {}

func _ready() -> void:
    if coastline == null:
        coastline = CoastlineScript.new()
        coastline.name = "CoastlineRenderer"
        add_child(coastline)
    super._ready()
    tile_removed.connect(_remove_terrain_data)
    var overview: Dictionary = manifest.get("overview", {})
    if overview.is_empty():
        return
    var path := data_root + "/" + str(overview.get("file", "overview.bin"))
    _far_thread = Thread.new()
    if _far_thread.start(_read_overview.bind(path, coast_root, int(overview.width), int(overview.depth))) != OK:
        push_error("Cannot start registered terrain overview reader")

func _exit_tree() -> void:
    if _far_thread != null and _far_thread.is_started():
        _far_thread.wait_to_finish()
    _far_build.clear()
    super._exit_tree()

func _process(delta: float) -> void:
    super._process(delta)
    _prepare_far()

func _remove_terrain_data(tile: Vector2i) -> void:
    var key := _tile_key(tile.x, tile.y)
    _height_data.erase(key)
    _coast_data.erase(key)
    if _far_sectors.has(key):
        _far_sectors[key].visible = true

func _make_materials() -> void:
    var fallback := StandardMaterial3D.new()
    fallback.vertex_color_use_as_albedo = true
    fallback.roughness = 0.98
    fallback.cull_mode = BaseMaterial3D.CULL_DISABLED
    _terrain_material = fallback

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
    var coast_geometry := CoastGeometryScript.new()
    if not coast_geometry.configure(coast_root):
        return
    var coast_manifest: Dictionary = coast_geometry.manifest
    if int(coast_manifest.resolution) != resolution or not is_equal_approx(float(coast_manifest.tile_size), tile_size) \
            or absf(float(coast_manifest.origin.easting) - float(manifest.origin.easting)) > 0.000001 \
            or absf(float(coast_manifest.origin.northing) - float(manifest.origin.northing)) > 0.000001:
        push_error("Coastline and terrain coordinate grids differ")
        return
    for item in manifest.tiles:
        _tile_files[_tile_key(int(item.x), int(item.z))] = str(item.file)
    print("Yardman terrain: %d cells, peak %.1f real metres; registered coast and beaches" %
        [manifest.tiles.size(), float(manifest.max_height)])

static func _read_height(path: String) -> Dictionary:
    if not FileAccess.file_exists(path):
        return {"error": "Missing terrain samples: " + path}
    var bytes := FileAccess.get_file_as_bytes(path)
    if bytes.is_empty() or bytes.size() % 4 != 0:
        return {"error": "Invalid terrain samples: " + path}
    var heights := bytes.to_float32_array()
    for height in heights:
        if not is_finite(height):
            return {"error": "Non-finite terrain height: " + path}
    return {"heights": heights}

static func _read_terrain(path: String, coast_path: String, tile: Vector2i, terrain_resolution: int) -> Dictionary:
    var payload := _read_height(path)
    if payload.has("error"):
        return payload
    var coast := CoastGeometryScript.read_tile(coast_path, tile, terrain_resolution)
    if coast.has("error"):
        return coast
    payload.coast = coast
    return payload

static func _read_overview(path: String, coast_path: String, width: int, depth: int) -> Dictionary:
    var payload := _read_height(path)
    if payload.has("error"):
        return payload
    if payload.heights.size() != width * depth:
        return {"error": "Wrong overview terrain sample count"}
    var coast := CoastGeometryScript.read_overview(coast_path, width, depth)
    if coast.has("error"):
        return coast
    payload.coast = coast
    return payload

func _start_jobs() -> void:
    while _jobs.size() < max_io_jobs and not _queue.is_empty():
        var key: String = _queue.pop_front()
        if not _wanted.has(key):
            continue
        var thread := Thread.new()
        var tile := _key_tile(key)
        var error := thread.start(_read_terrain.bind("%s/%s" % [data_root, _tile_files[key]], coast_root, tile, resolution))
        if error != OK:
            _failed[key] = true
            push_error("Cannot start terrain/coast reader")
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
        _building = {"key": key, "tile": tile, "root": tile_root, "heights": payload.heights,
            "coast": payload.coast, "cursor": 0, "land_cursor": 0,
            "vertices": PackedVector3Array(), "indices": PackedInt32Array(),
            "normals": PackedVector3Array(), "colors": PackedColorArray()}

func _prepare_geometry() -> void:
    if _building.is_empty():
        return
    var start := Time.get_ticks_usec()
    while int(_building.cursor) < resolution:
        _append_height_row(_building, int(_building.cursor))
        _building.cursor += 1
        if Time.get_ticks_usec() - start >= geometry_budget_us:
            return
    var land: PackedVector3Array = _building.coast.land
    while int(_building.land_cursor) < land.size():
        _append_near_triangle(_building, land, int(_building.land_cursor))
        _building.land_cursor += 3
        if Time.get_ticks_usec() - start >= geometry_budget_us:
            return
    _complete_near()

func _height_color(height: float, slope: float) -> Color:
    if height < 2.0:
        return Color(0.38, 0.43, 0.25)
    var low := Color(0.24, 0.38, 0.14)
    var high := Color(0.12, 0.26, 0.18)
    var color := low.lerp(high, clampf(height / 1800.0, 0.0, 1.0))
    return color.lerp(Color(0.48, 0.43, 0.34), clampf((slope - 0.45) * 0.8, 0.0, 0.65))

func _append_height_row(job: Dictionary, z: int) -> void:
    var heights: PackedFloat32Array = job.heights
    var mask: PackedByteArray = job.coast.mask
    for x in range(resolution):
        var y := float(heights[z * resolution + x])
        var dx := (float(heights[z * resolution + maxi(x - 1, 0)]) - float(heights[z * resolution + mini(x + 1, resolution - 1)])) / (2.0 * spacing)
        var dz := (float(heights[maxi(z - 1, 0) * resolution + x]) - float(heights[mini(z + 1, resolution - 1) * resolution + x])) / (2.0 * spacing)
        job.vertices.append(Vector3(float(x) * spacing, y, float(z) * spacing))
        job.normals.append(Vector3(dx, 1.0, dz).normalized())
        job.colors.append(_height_color(y, Vector2(dx, dz).length()))
        if x == resolution - 1 or z == resolution - 1:
            continue
        if mask[z * (resolution - 1) + x] != 1:
            continue
        var a := z * resolution + x
        var b := a + 1
        var c := a + resolution
        var d := c + 1
        job.indices.append_array(PackedInt32Array([a, c, b, b, c, d]))

func _append_near_triangle(job: Dictionary, vertices: PackedVector3Array, cursor: int) -> void:
    var a := vertices[cursor]
    var b := vertices[cursor + 1]
    var c := vertices[cursor + 2]
    var cross := (b - a).cross(c - a)
    if cross.length_squared() < 0.000000000001:
        return
    var normal := cross.normalized()
    var slope := Vector2(normal.x, normal.z).length() / maxf(absf(normal.y), 0.001)
    var first: int = job.vertices.size()
    for point in [a, b, c]:
        job.vertices.append(point)
        job.normals.append(normal)
        job.colors.append(_height_color(point.y, slope))
    job.indices.append_array(PackedInt32Array([first, first + 1, first + 2]))

func _mesh(job: Dictionary, origin: Vector2, overview: bool = false) -> ArrayMesh:
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
    var material: Material = _terrain_material
    if visuals != null and visuals.has_method("terrain_material"):
        material = visuals.terrain_material(origin, overview)
    mesh.surface_set_material(0, material)
    return mesh

func _complete_near() -> void:
    var tile_root: Node3D = _building.root
    var tile: Vector2i = _building.tile
    var key: String = _building.key
    var mesh := _mesh(_building, Vector2(float(tile.x) * tile_size, float(tile.y) * tile_size))
    if mesh.get_surface_count() > 0:
        var instance := MeshInstance3D.new()
        instance.name = "RegisteredLand"
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
    coastline.instantiate_tile(tile, _building.coast, tile_root, tile_size)
    _height_data[key] = _building.heights
    _coast_data[key] = _building.coast
    add_child(tile_root)
    _loaded[key] = tile_root
    if _far_sectors.has(key):
        _far_sectors[key].visible = false
    _building.clear()
    tile_ready.emit(tile)

func height_at(x: float, z: float) -> float:
    if not is_finite(x) or not is_finite(z):
        return NAN
    var tile := coordinates.tile_for(x, z)
    var key := _tile_key(tile.x, tile.y)
    var heights: PackedFloat32Array = _height_data.get(key, PackedFloat32Array())
    if heights.is_empty():
        return NAN
    var local_x := x - float(tile.x) * tile_size
    var local_z := z - float(tile.y) * tile_size
    if not CoastGeometryScript.contains_land(_coast_data.get(key, {}), local_x, local_z, spacing, resolution):
        return NAN
    var fx := local_x / spacing
    var fz := local_z / spacing
    var ix := clampi(int(fx), 0, resolution - 2)
    var iz := clampi(int(fz), 0, resolution - 2)
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
        _far_root = Node3D.new()
        _far_root.name = "IslandOverviewLOD"
        add_child(_far_root)
        _far_build = {"heights": payload.heights, "coast": payload.coast, "row": 0, "column": 0,
            "phase": 0, "land_cursor": 0, "water_cursor": 0, "groups": {}, "group_keys": [], "assemble_cursor": 0,
            "origin_x": coordinates.render_origin_x, "origin_y": coordinates.render_origin_y, "origin_z": coordinates.render_origin_z}
    if _far_build.is_empty() or _loaded.is_empty():
        return
    var start := Time.get_ticks_usec()
    var overview: Dictionary = manifest.overview
    while Time.get_ticks_usec() - start < geometry_budget_us:
        match int(_far_build.phase):
            0:
                if int(_far_build.row) >= int(overview.depth) - 1:
                    _far_build.phase = 1
                    continue
                _append_far_cell(int(_far_build.column), int(_far_build.row), overview)
                _far_build.column += 1
                if int(_far_build.column) >= int(overview.width) - 1:
                    _far_build.column = 0
                    _far_build.row += 1
            1:
                var land: PackedVector3Array = _far_build.coast.land
                if int(_far_build.land_cursor) >= land.size():
                    _far_build.phase = 2
                    continue
                var cursor: int = _far_build.land_cursor
                _append_far_land(land[cursor], land[cursor + 1], land[cursor + 2], overview)
                _far_build.land_cursor += 3
            2:
                var water: PackedVector3Array = _far_build.coast.water
                if int(_far_build.water_cursor) >= water.size():
                    _far_build.group_keys = _far_build.groups.keys()
                    _far_build.group_keys.sort()
                    _far_build.phase = 3
                    continue
                _append_far_water(int(_far_build.water_cursor), overview)
                _far_build.water_cursor += 3
            3:
                if int(_far_build.assemble_cursor) >= _far_build.group_keys.size():
                    _far_build.clear()
                    print("Yardman island overview: %d independent land/ocean sectors" % _far_sectors.size())
                    return
                var key: String = _far_build.group_keys[int(_far_build.assemble_cursor)]
                _assemble_far_sector(key)
                _far_build.groups.erase(key)
                _far_build.assemble_cursor += 1

func _far_group(tile: Vector2i) -> Dictionary:
    var key := _tile_key(tile.x, tile.y)
    if not _far_build.groups.has(key):
        _far_build.groups[key] = {"tile": tile, "vertices": PackedVector3Array(), "normals": PackedVector3Array(),
            "colors": PackedColorArray(), "indices": PackedInt32Array(),
            "water": PackedVector3Array(), "shore_distance": PackedFloat32Array()}
    return _far_build.groups[key]

func _append_far_cell(x: int, z: int, overview: Dictionary) -> void:
    var width := int(overview.width)
    var mask: PackedByteArray = _far_build.coast.mask
    if mask[z * (width - 1) + x] != 1:
        return
    var heights: PackedFloat32Array = _far_build.heights
    var step := float(overview.spacing)
    var a := Vector3(float(x) * step, heights[z * width + x], float(z) * step)
    var b := Vector3(float(x + 1) * step, heights[z * width + x + 1], float(z) * step)
    var c := Vector3(float(x) * step, heights[(z + 1) * width + x], float(z + 1) * step)
    var d := Vector3(float(x + 1) * step, heights[(z + 1) * width + x + 1], float(z + 1) * step)
    _append_far_land(a, c, b, overview)
    _append_far_land(b, c, d, overview)

func _append_far_land(a: Vector3, b: Vector3, c: Vector3, overview: Dictionary) -> void:
    var cross := (b - a).cross(c - a)
    if cross.length_squared() < 0.000000000001:
        return
    var normal := cross.normalized()
    var center := (a + b + c) / 3.0
    var ox := float(overview.origin_x)
    var oz := float(overview.origin_z)
    var tile := coordinates.tile_for(ox + float(center.x), oz + float(center.z))
    var group := _far_group(tile)
    var first: int = group.vertices.size()
    var slope := Vector2(normal.x, normal.z).length() / maxf(absf(normal.y), 0.001)
    for source in [a, b, c]:
        var vertex := Vector3(ox + float(source.x) - float(tile.x) * tile_size, source.y,
            oz + float(source.z) - float(tile.y) * tile_size)
        group.vertices.append(vertex)
        group.normals.append(normal)
        group.colors.append(_height_color(vertex.y, slope))
    group.indices.append_array(PackedInt32Array([first, first + 1, first + 2]))

func _append_far_water(cursor: int, overview: Dictionary) -> void:
    var water: PackedVector3Array = _far_build.coast.water
    var distances: PackedFloat32Array = _far_build.coast.shore_distance
    var center := (water[cursor] + water[cursor + 1] + water[cursor + 2]) / 3.0
    var ox := float(overview.origin_x)
    var oz := float(overview.origin_z)
    var tile := coordinates.tile_for(ox + float(center.x), oz + float(center.z))
    var group := _far_group(tile)
    for offset in range(3):
        var source := water[cursor + offset]
        group.water.append(Vector3(ox + float(source.x) - float(tile.x) * tile_size, 0.0,
            oz + float(source.z) - float(tile.y) * tile_size))
        group.shore_distance.append(distances[cursor + offset])

func _assemble_far_sector(key: String) -> void:
    var group: Dictionary = _far_build.groups[key]
    var tile: Vector2i = group.tile
    var sector := Node3D.new()
    sector.name = "Overview_%d_%d" % [tile.x, tile.y]
    sector.position = Vector3(float(tile.x) * tile_size - float(_far_build.origin_x),
        -float(_far_build.origin_y), float(tile.y) * tile_size - float(_far_build.origin_z))
    var origin := Vector2(float(tile.x) * tile_size, float(tile.y) * tile_size)
    var mesh := _mesh(group, origin, true)
    if mesh.get_surface_count() > 0:
        var land := MeshInstance3D.new()
        land.name = "OverviewLand"
        land.mesh = mesh
        land.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        sector.add_child(land)
    coastline.append_water(group, sector, origin.x, origin.y)
    sector.visible = not _loaded.has(key)
    _far_root.add_child(sector)
    _far_sectors[key] = sector
