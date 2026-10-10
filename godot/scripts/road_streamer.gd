extends Node3D
class_name JamaicaRoadStreamer

const CoordinatesScript = preload("res://scripts/world_coordinates.gd")
const GraphScript = preload("res://scripts/road_graph.gd")
const RoadShader = preload("res://shaders/road_surface.gdshader")
const SURFACE_CELL_SIZE := 128.0
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
var _asphalt_material: ShaderMaterial
var _dirt_material: ShaderMaterial
var _surface_indices: Dictionary = {}
var surface_visibility_distance := 2600.0:
    set(value):
        surface_visibility_distance = clampf(value, 600.0, 3800.0)
        for material in [_asphalt_material, _dirt_material]:
            if material != null:
                material.set_shader_parameter("visibility_distance", surface_visibility_distance)

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
    _asphalt_material = ShaderMaterial.new()
    _asphalt_material.shader = RoadShader
    _asphalt_material.set_shader_parameter("visibility_distance", surface_visibility_distance)
    _dirt_material = ShaderMaterial.new()
    _dirt_material.shader = RoadShader
    _dirt_material.set_shader_parameter("unpaved", true)
    _dirt_material.set_shader_parameter("visibility_distance", surface_visibility_distance)

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
            _surface_indices.erase(key)
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
            "paved_normals": PackedVector3Array(), "paved_uv": PackedVector2Array(),
            "paved_uv2": PackedVector2Array(), "paved_colors": PackedColorArray(),
            "dirt_vertices": PackedVector3Array(), "dirt_indices": PackedInt32Array(),
            "dirt_normals": PackedVector3Array(), "dirt_uv": PackedVector2Array(),
            "dirt_uv2": PackedVector2Array(), "dirt_colors": PackedColorArray(), "surface_index": {}}

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
                _building.dirt_indices if dirt else _building.paved_indices,
                _building.dirt_normals if dirt else _building.paved_normals,
                _building.dirt_uv if dirt else _building.paved_uv,
                _building.dirt_uv2 if dirt else _building.paved_uv2,
                _building.dirt_colors if dirt else _building.paved_colors, segment, _building.tile)
            _index_surface_segment(_building.surface_index, segment)
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
        _surface_indices[key] = _building.surface_index
        _building.clear()
        tile_ready.emit(tile)
        tile_content_ready.emit(tile, tile_root, segments)

func _append_segment(vertices: PackedVector3Array, indices: PackedInt32Array,
        normals: PackedVector3Array, uvs: PackedVector2Array, uv2s: PackedVector2Array,
        colors: PackedColorArray, segment: Array, tile: Vector2i) -> void:
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
    if polygon.size() < 3:
        return
    var base := vertices.size()
    var a := Vector3(float(polygon[0][0]) - origin_x, float(polygon[0][1]), float(polygon[0][2]) - origin_z)
    var normal := Vector3.UP
    for i in range(1, polygon.size() - 1):
        var b := Vector3(float(polygon[i][0]) - origin_x, float(polygon[i][1]), float(polygon[i][2]) - origin_z)
        var c := Vector3(float(polygon[i + 1][0]) - origin_x, float(polygon[i + 1][1]), float(polygon[i + 1][2]) - origin_z)
        var candidate := (c - a).cross(b - a)
        if candidate.length_squared() > 0.000001:
            normal = candidate.normalized()
            if normal.y < 0.0:
                normal = -normal
            break
    var width := maxf(float(segment[4]), 1.0)
    var paint := int(segment[13]) if segment.size() > 13 else 0
    var lanes := int(segment[14]) if segment.size() > 14 else 2
    var start_station := float(segment[16]) if segment.size() > 16 else 0.0
    var end_station := float(segment[17]) if segment.size() > 17 else 1000000.0
    # Different source ways can overlap at a real at-grade junction. A tiny
    # stable source-way bias prevents equal-depth asphalt from flickering,
    # while all graph pieces/tiles of the same way share one exact offset.
    var source_way := str(segment[7]).get_slice(":", 0) if segment.size() > 7 else "legacy"
    var height_bias := 0.14 + float(source_way.hash() % 32) * 0.001
    var tangent := Vector2(float(segment[2]) - float(segment[0]), float(segment[3]) - float(segment[1])).normalized()
    for vertex_index in range(polygon.size()):
        var p: Array = polygon[vertex_index]
        # A local decimetre overlay plus a near camera plane and bounded draw
        # distance avoids precision fighting the 45 km overview depth range.
        vertices.append(Vector3(float(p[0]) - origin_x, float(p[1]) + height_bias, float(p[2]) - origin_z))
        normals.append(normal)
        var uv := Vector2.ZERO
        if segment.size() > 12 and segment[12].size() == polygon.size():
            uv = Vector2(float(segment[12][vertex_index][0]), float(segment[12][vertex_index][1]))
        else:
            var relative := Vector2(float(p[0]) - float(segment[0]), float(p[2]) - float(segment[1]))
            uv = Vector2(relative.dot(tangent), relative.dot(Vector2(-tangent.y, tangent.x)))
        uvs.append(uv)
        uv2s.append(Vector2(maxf(0.0, uv.x - start_station), maxf(0.0, end_station - uv.x)))
        colors.append(Color(width / 32.0, float(paint) / 2.0, float(lanes) / 8.0, 1.0))
    for i in range(1, polygon.size() - 1):
        # Ribbons are counterclockwise in X/Z. Reverse for Godot's upward
        # facing front side rather than relying on double-sided backfaces.
        indices.append_array(PackedInt32Array([base, base + i + 1, base + i]))

func _flush_mesh_batch() -> void:
    for prefix in ["paved", "dirt"]:
        _add_surface_mesh(_building.root, _building[prefix + "_vertices"], _building[prefix + "_indices"],
            _building[prefix + "_normals"], _building[prefix + "_uv"], _building[prefix + "_uv2"],
            _building[prefix + "_colors"], _asphalt_material if prefix == "paved" else _dirt_material, prefix)
        _building[prefix + "_vertices"] = PackedVector3Array()
        _building[prefix + "_indices"] = PackedInt32Array()
        _building[prefix + "_normals"] = PackedVector3Array()
        _building[prefix + "_uv"] = PackedVector2Array()
        _building[prefix + "_uv2"] = PackedVector2Array()
        _building[prefix + "_colors"] = PackedColorArray()
    _building.batch += 1

func _add_surface_mesh(parent: Node3D, vertices: PackedVector3Array, indices: PackedInt32Array,
        normals: PackedVector3Array, uvs: PackedVector2Array, uv2s: PackedVector2Array,
        colors: PackedColorArray, material: Material, label: String) -> void:
    if vertices.is_empty():
        return
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = normals
    arrays[Mesh.ARRAY_INDEX] = indices
    arrays[Mesh.ARRAY_TEX_UV] = uvs
    arrays[Mesh.ARRAY_TEX_UV2] = uv2s
    arrays[Mesh.ARRAY_COLOR] = colors
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    mesh.surface_set_material(0, material)
    var instance := MeshInstance3D.new()
    instance.name = label
    instance.mesh = mesh
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    parent.add_child(instance)

func _index_surface_segment(index: Dictionary, segment: Array) -> void:
    if segment.size() < 12 or segment[11].is_empty():
        return
    var identifier := "%s:%d" % [str(segment[7]), int(segment[8])]
    var minimum := Vector2(INF, INF)
    var maximum := Vector2(-INF, -INF)
    for point in segment[11]:
        minimum.x = minf(minimum.x, float(point[0]))
        minimum.y = minf(minimum.y, float(point[2]))
        maximum.x = maxf(maximum.x, float(point[0]))
        maximum.y = maxf(maximum.y, float(point[2]))
    var first := Vector2i(floori(minimum.x / SURFACE_CELL_SIZE), floori(minimum.y / SURFACE_CELL_SIZE))
    var last := Vector2i(floori((maximum.x - 0.00001) / SURFACE_CELL_SIZE), floori((maximum.y - 0.00001) / SURFACE_CELL_SIZE))
    for z in range(first.y, last.y + 1):
        for x in range(first.x, last.x + 1):
            var cell := Vector2i(x, z)
            if not index.has(cell):
                index[cell] = {}
            if not index[cell].has(identifier):
                # Do not retain the many terrain-triangle polygon records.
                # One logical segment record per occupied 128 m cell is enough.
                index[cell][identifier] = {"a": Vector2(float(segment[0]), float(segment[1])),
                    "b": Vector2(float(segment[2]), float(segment[3])), "width_m": float(segment[4]),
                    "class_id": int(segment[5]), "flags": int(segment[6]), "edge_id": str(segment[7]),
                    "speed_limit_mps": segment[15] if segment.size() > 15 else null}

func _nearby_surface_segments(x: float, z: float, radius: float) -> Dictionary:
    var result: Dictionary = {}
    if not is_finite(x) or not is_finite(z) or not is_finite(radius):
        return result
    var reach := clampf(radius, 1.0, 512.0)
    var first := Vector2i(floori((x - reach) / SURFACE_CELL_SIZE), floori((z - reach) / SURFACE_CELL_SIZE))
    var last := Vector2i(floori((x + reach) / SURFACE_CELL_SIZE), floori((z + reach) / SURFACE_CELL_SIZE))
    for cz in range(first.y, last.y + 1):
        for cx in range(first.x, last.x + 1):
            var cell := Vector2i(cx, cz)
            var tile := coordinates.tile_for((float(cx) + 0.5) * SURFACE_CELL_SIZE, (float(cz) + 0.5) * SURFACE_CELL_SIZE)
            var tile_index: Dictionary = _surface_indices.get(_tile_key(tile.x, tile.y), {})
            var records: Dictionary = tile_index.get(cell, {})
            for identifier in records:
                result[identifier] = records[identifier]
    return result

static func _segment_distance_squared(point: Vector2, a: Vector2, b: Vector2) -> float:
    var direction := b - a
    var length_squared := direction.length_squared()
    if length_squared < 0.000001:
        return point.distance_squared_to(a)
    var fraction := clampf((point - a).dot(direction) / length_squared, 0.0, 1.0)
    return point.distance_squared_to(a + direction * fraction)

func road_surface_at(x: float, z: float) -> Dictionary:
    var nearest: Dictionary = {"found": false, "surface": "offroad", "distance_m": INF}
    var point := Vector2(x, z)
    var nearest_squared := INF
    var records := _nearby_surface_segments(x, z, 32.0)
    for record: Dictionary in records.values():
        var distance_squared := _segment_distance_squared(point, record.a, record.b)
        var on_surface := distance_squared <= pow(float(record.width_m) * 0.5 + 0.15, 2.0)
        if nearest.found and not on_surface:
            continue
        if on_surface == bool(nearest.found) and distance_squared >= nearest_squared:
            continue
        nearest_squared = distance_squared
        var tangent: Vector2 = record.b - record.a
        nearest = record.duplicate()
        nearest["found"] = on_surface
        nearest["distance_m"] = sqrt(distance_squared)
        nearest["surface"] = ("unpaved" if (int(record.flags) & 8) != 0 else "paved") if on_surface else "offroad"
        nearest["heading"] = atan2(-tangent.x, -tangent.y)
    return nearest

func nearby_paths(x: float, z: float, radius: float = 220.0) -> Array[PackedVector2Array]:
    var paths: Array[PackedVector2Array] = []
    var reach := clampf(radius, 1.0, 512.0)
    var point := Vector2(x, z)
    var records := _nearby_surface_segments(x, z, reach)
    var identifiers: Array = records.keys()
    identifiers.sort()
    for identifier in identifiers:
        var record: Dictionary = records[identifier]
        if _segment_distance_squared(point, record.a, record.b) <= reach * reach:
            paths.append(PackedVector2Array([record.a, record.b]))
            if paths.size() >= 384:
                break
    return paths

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
