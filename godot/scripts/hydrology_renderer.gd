extends Node3D
class_name YardmanHydrologyRenderer

const WATER_SHADER = preload("res://shaders/river_surface.gdshader")
const MeshGeometryGuard = preload("res://scripts/mesh_geometry_guard.gd")
const DEFAULT_ACTIVE_RADIUS := 1
const DEFAULT_VERTEX_CAP := 12000
const WATER_LIFT_M := 0.075
const UV_METRES_PER_REPEAT := 8.0
const AUDIO_SEGMENT_CAP_PER_TILE := 96
const V2_RECORD_FORMAT := [
    "local_ax", "ay", "local_az", "local_bx", "by", "local_bz",
    "source_way", "waterway", "name", "width_m", "width_source",
    "intermittent", "tidal", "grade_permille", "channel_seed_depth_m",
    "channel_depth_source", "segment_key", "morphology_status", "morphology_family", "crossings",
]

var terrain
var coordinates
var data_root := ""
var manifest: Dictionary = {}
var tile_size := 4096.0
var active_radius := DEFAULT_ACTIVE_RADIUS
var vertex_cap := DEFAULT_VERTEX_CAP
var _format_version := 0
var _tile_files: Dictionary = {}
var _loaded: Dictionary = {}
var _audio_geometry: Dictionary = {}
var _water_material: ShaderMaterial
var _last_center := Vector2i(2147483647, 2147483647)

func configure(root_path: String, coordinate_system, terrain_streamer) -> bool:
    data_root = root_path.trim_suffix("/")
    coordinates = coordinate_system
    terrain = terrain_streamer
    if data_root.is_empty() or coordinates == null or terrain == null:
        return false
    var manifest_path := data_root + "/manifest.json"
    if not FileAccess.file_exists(manifest_path):
        return false
    var parsed = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
    if not parsed is Dictionary:
        return false
    var version := int(parsed.get("format_version", 0))
    var pack_id := str(parsed.get("pack_id", ""))
    if version == 1:
        if pack_id != "jamaica_hydrology_osm_v1":
            return false
    elif version == 2:
        if pack_id != "jamaica_hydrology_reconciled_v2":
            return false
        if parsed.get("record_format", []) != V2_RECORD_FORMAT:
            push_error("Reconciled hydrology record format differs from runtime contract")
            return false
    else:
        return false
    if str(parsed.get("crs", "")) != "EPSG:3448":
        return false
    manifest = parsed
    _format_version = version
    tile_size = float(manifest.get("tile_size", 4096.0))
    var policy: Dictionary = manifest.get("render_policy", {})
    active_radius = clampi(int(policy.get("active_tile_radius", DEFAULT_ACTIVE_RADIUS)), 0, 2)
    vertex_cap = clampi(int(policy.get("max_vertices_per_tile", DEFAULT_VERTEX_CAP)), 1000, 24000)
    _tile_files.clear()
    _audio_geometry.clear()
    for raw in manifest.get("tiles", []):
        if not raw is Dictionary:
            continue
        var record: Dictionary = raw
        var key := _tile_key(int(record.get("x", 0)), int(record.get("z", 0)))
        _tile_files[key] = str(record.get("file", ""))
    _water_material = ShaderMaterial.new()
    _water_material.shader = WATER_SHADER
    _water_material.set_shader_parameter("flow_speed", 0.72)
    _water_material.set_shader_parameter("ripple_scale", 2.4)
    return not _tile_files.is_empty()

func format_version() -> int:
    return _format_version

func uses_compiled_dem_elevation() -> bool:
    return _format_version == 2

func update_world(world_x: float, world_z: float) -> void:
    if coordinates == null or manifest.is_empty():
        return
    var center: Vector2i = coordinates.tile_for(world_x, world_z)
    var wanted: Dictionary = {}
    for dz in range(-active_radius, active_radius + 1):
        for dx in range(-active_radius, active_radius + 1):
            var tile := Vector2i(center.x + dx, center.y + dz)
            var key := _tile_key(tile.x, tile.y)
            if _tile_files.has(key):
                wanted[key] = tile
    for key in _loaded.keys().duplicate():
        if wanted.has(key):
            continue
        var old = _loaded[key]
        if is_instance_valid(old):
            old.queue_free()
        _loaded.erase(key)
        _audio_geometry.erase(key)
    for key in wanted.keys():
        var tile: Vector2i = wanted[key]
        if not _loaded.has(key):
            _try_load_tile(tile)
    _last_center = center
    _reposition_loaded()

func clear() -> void:
    for node in _loaded.values():
        if is_instance_valid(node):
            node.queue_free()
    _loaded.clear()
    _audio_geometry.clear()
    _last_center = Vector2i(2147483647, 2147483647)

func loaded_tile_count() -> int:
    return _loaded.size()

func audio_segment_count() -> int:
    var total := 0
    for raw in _audio_geometry.values():
        if raw is Dictionary:
            total += (raw as Dictionary).get("segments", PackedVector4Array()).size()
    return total

func nearest_water_distance(world_x: float, world_z: float, max_distance: float = 180.0) -> float:
    if not is_finite(world_x) or not is_finite(world_z) or not is_finite(max_distance) or max_distance <= 0.0:
        return INF
    var point := Vector2(world_x, world_z)
    var best := max_distance
    for raw in _audio_geometry.values():
        if not raw is Dictionary:
            continue
        var geometry: Dictionary = raw
        var segments: PackedVector4Array = geometry.get("segments", PackedVector4Array())
        var half_widths: PackedFloat32Array = geometry.get("half_widths", PackedFloat32Array())
        var count := mini(segments.size(), half_widths.size())
        for index in range(count):
            var segment := segments[index]
            var a := Vector2(segment.x, segment.y)
            var b := Vector2(segment.z, segment.w)
            var delta := b - a
            var t := clampf((point - a).dot(delta) / maxf(delta.length_squared(), 0.000001), 0.0, 1.0)
            var edge_distance := maxf(0.0, point.distance_to(a + delta * t) - float(half_widths[index]))
            if edge_distance < best:
                best = edge_distance
                if best <= 0.01:
                    return 0.0
    return best if best < max_distance else INF

func _try_load_tile(tile: Vector2i) -> bool:
    var key := _tile_key(tile.x, tile.y)
    if not _tile_files.has(key):
        return false
    var filename := str(_tile_files[key])
    if filename.is_empty() or filename.contains("/") or filename.contains("\\") or filename.contains(".."):
        return false
    var path := data_root + "/" + filename
    if not FileAccess.file_exists(path):
        return false
    var payload = JSON.parse_string(FileAccess.get_file_as_string(path))
    if not payload is Dictionary or int(payload.get("format_version", 0)) != _format_version:
        return false
    var payload_tile: Array = payload.get("tile", [])
    if payload_tile.size() != 2 or int(payload_tile[0]) != tile.x or int(payload_tile[1]) != tile.y:
        return false
    var mesh := _build_tile_mesh(tile, payload)
    if mesh == null or mesh.get_surface_count() == 0:
        return false
    var instance := MeshInstance3D.new()
    instance.name = "Hydrology_%d_%d" % [tile.x, tile.y]
    instance.mesh = mesh
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    instance.visibility_range_end = 1700.0
    instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
    instance.position = coordinates.world_to_local(float(tile.x) * tile_size, float(tile.y) * tile_size, 0.0)
    add_child(instance)
    _loaded[key] = instance
    _audio_geometry[key] = _build_audio_geometry(tile, payload)
    return true

func _build_audio_geometry(tile: Vector2i, payload: Dictionary) -> Dictionary:
    return _build_audio_geometry_v2(tile, payload) if _format_version == 2 else _build_audio_geometry_v1(tile, payload)

func _build_audio_geometry_v1(tile: Vector2i, payload: Dictionary) -> Dictionary:
    var all_segments: Array[Vector4] = []
    var all_widths: Array[float] = []
    var tile_world_x := float(tile.x) * tile_size
    var tile_world_z := float(tile.y) * tile_size
    for raw_record in payload.get("waterways", []):
        if not raw_record is Dictionary:
            continue
        var record: Dictionary = raw_record
        var width := clampf(float(record.get("width_m", 2.5)), 0.7, 45.0)
        if bool(record.get("intermittent", false)):
            width *= 0.82
        for raw_part in record.get("parts", []):
            if not raw_part is Array or raw_part.size() < 2:
                continue
            for point_index in range(raw_part.size() - 1):
                var raw_a = raw_part[point_index]
                var raw_b = raw_part[point_index + 1]
                if not raw_a is Array or not raw_b is Array or raw_a.size() < 2 or raw_b.size() < 2:
                    continue
                var ax := tile_world_x + float(raw_a[0])
                var az := tile_world_z + float(raw_a[1])
                var bx := tile_world_x + float(raw_b[0])
                var bz := tile_world_z + float(raw_b[1])
                if not is_finite(ax) or not is_finite(az) or not is_finite(bx) or not is_finite(bz):
                    continue
                if Vector2(ax, az).distance_squared_to(Vector2(bx, bz)) < 0.01:
                    continue
                all_segments.append(Vector4(ax, az, bx, bz))
                all_widths.append(width * 0.5)
    return _cap_audio_geometry(all_segments, all_widths)

func _build_audio_geometry_v2(tile: Vector2i, payload: Dictionary) -> Dictionary:
    var all_segments: Array[Vector4] = []
    var all_widths: Array[float] = []
    var tile_world_x := float(tile.x) * tile_size
    var tile_world_z := float(tile.y) * tile_size
    for raw in payload.get("segments", []):
        if not raw is Array or raw.size() < V2_RECORD_FORMAT.size():
            continue
        var ax := tile_world_x + float(raw[0])
        var az := tile_world_z + float(raw[2])
        var bx := tile_world_x + float(raw[3])
        var bz := tile_world_z + float(raw[5])
        if not is_finite(ax) or not is_finite(az) or not is_finite(bx) or not is_finite(bz):
            continue
        if Vector2(ax, az).distance_squared_to(Vector2(bx, bz)) < 0.01:
            continue
        var width := clampf(float(raw[9]), 0.7, 45.0)
        if bool(raw[11]):
            width *= 0.82
        all_segments.append(Vector4(ax, az, bx, bz))
        all_widths.append(width * 0.5)
    return _cap_audio_geometry(all_segments, all_widths)

func _cap_audio_geometry(all_segments: Array[Vector4], all_widths: Array[float]) -> Dictionary:
    var segments := PackedVector4Array()
    var half_widths := PackedFloat32Array()
    if all_segments.is_empty():
        return {"segments": segments, "half_widths": half_widths}
    var stride := maxi(1, int(ceil(float(all_segments.size()) / float(AUDIO_SEGMENT_CAP_PER_TILE))))
    var index := 0
    while index < all_segments.size() and segments.size() < AUDIO_SEGMENT_CAP_PER_TILE:
        segments.append(all_segments[index])
        half_widths.append(all_widths[index])
        index += stride
    return {"segments": segments, "half_widths": half_widths}

func _build_tile_mesh(tile: Vector2i, payload: Dictionary) -> ArrayMesh:
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var uvs := PackedVector2Array()
    var indices := PackedInt32Array()
    if _format_version == 2:
        _append_v2_tile(tile, payload, vertices, normals, uvs, indices)
    else:
        _append_v1_tile(tile, payload, vertices, normals, uvs, indices)
    if indices.is_empty():
        return null
    var safety := MeshGeometryGuard.validate(vertices, indices, tile_size * 1.75, tile_size * 1.75, vertex_cap)
    if not bool(safety.get("ok", false)):
        push_error(MeshGeometryGuard.rejection_message("hydrology tile %d:%d" % [tile.x, tile.y], safety))
        return null
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = normals
    arrays[Mesh.ARRAY_TEX_UV] = uvs
    arrays[Mesh.ARRAY_INDEX] = indices
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    mesh.surface_set_material(0, _water_material)
    return mesh

func _append_v1_tile(tile: Vector2i, payload: Dictionary, vertices: PackedVector3Array,
        normals: PackedVector3Array, uvs: PackedVector2Array, indices: PackedInt32Array) -> void:
    var tile_world_x := float(tile.x) * tile_size
    var tile_world_z := float(tile.y) * tile_size
    for raw_record in payload.get("waterways", []):
        if not raw_record is Dictionary:
            continue
        var record: Dictionary = raw_record
        var width := clampf(float(record.get("width_m", 2.5)), 0.7, 45.0)
        if bool(record.get("intermittent", false)):
            width *= 0.82
        for raw_part in record.get("parts", []):
            if not raw_part is Array or raw_part.size() < 2:
                continue
            if vertices.size() + raw_part.size() * 2 > vertex_cap:
                break
            _append_ribbon_part(raw_part, width, tile_world_x, tile_world_z, vertices, normals, uvs, indices)
        if vertices.size() >= vertex_cap:
            break

func _append_v2_tile(tile: Vector2i, payload: Dictionary, vertices: PackedVector3Array,
        normals: PackedVector3Array, uvs: PackedVector2Array, indices: PackedInt32Array) -> void:
    var tile_world_x := float(tile.x) * tile_size
    var tile_world_z := float(tile.y) * tile_size
    for raw in payload.get("segments", []):
        if not raw is Array or raw.size() < V2_RECORD_FORMAT.size():
            continue
        if vertices.size() + 4 > vertex_cap:
            break
        var width := clampf(float(raw[9]), 0.7, 45.0)
        if bool(raw[11]):
            width *= 0.82
        var a := Vector3(float(raw[0]), float(raw[1]), float(raw[2]))
        var b := Vector3(float(raw[3]), float(raw[4]), float(raw[5]))
        if not _finite_vector(a) or not _finite_vector(b):
            continue
        var horizontal_length := Vector2(b.x - a.x, b.z - a.z).length()
        if horizontal_length < 0.1:
            continue
        var crossings: Array = raw[19] if raw[19] is Array else []
        var intervals := _visible_intervals(a, b, width, crossings, tile_world_x, tile_world_z)
        for interval in intervals:
            if vertices.size() + 4 > vertex_cap:
                return
            _append_compiled_ribbon(a, b, width, interval, horizontal_length, vertices, normals, uvs, indices)

func _visible_intervals(a: Vector3, b: Vector3, width: float, crossings: Array,
        tile_world_x: float, tile_world_z: float) -> Array[Vector2]:
    var hidden: Array[Vector2] = []
    var direction := Vector2(b.x - a.x, b.z - a.z)
    var length_squared := direction.length_squared()
    var length := sqrt(length_squared)
    if length <= 0.0001:
        return []
    for raw_crossing in crossings:
        if not raw_crossing is Dictionary:
            continue
        var crossing: Dictionary = raw_crossing
        var status := str(crossing.get("status", "unresolved"))
        var kind := str(crossing.get("kind", "unknown"))
        # Open water remains continuous where the source explicitly says the
        # road is above/below it or the crossing is an at-grade ford. Culverts
        # are enclosed below the road; unresolved/conflicting crossings are
        # clipped rather than pretending that water visibly runs over asphalt.
        if status == "approved" and kind in ["bridge", "ford", "road_tunnel"]:
            continue
        if status == "approved" and kind != "culvert":
            continue
        var world_x := float(crossing.get("x", NAN))
        var world_z := float(crossing.get("z", NAN))
        if not is_finite(world_x) or not is_finite(world_z):
            continue
        var point := Vector2(world_x - tile_world_x, world_z - tile_world_z)
        var local_a := Vector2(a.x, a.z)
        var t := clampf((point - local_a).dot(direction) / length_squared, 0.0, 1.0)
        var nearest := local_a + direction * t
        if nearest.distance_to(point) > 1.0:
            continue
        var road_width_m := float(crossing.get("road_width_m", 0.0))
        var half_gap_m := maxf(width * 0.75, road_width_m * 0.5 + 1.25) if road_width_m > 0.0 else maxf(4.0, width * 0.75)
        var radius_t := minf(0.49, half_gap_m / length)
        hidden.append(Vector2(maxf(0.0, t - radius_t), minf(1.0, t + radius_t)))
    if hidden.is_empty():
        return [Vector2(0.0, 1.0)]
    hidden.sort_custom(func(left: Vector2, right: Vector2) -> bool: return left.x < right.x)
    var merged: Array[Vector2] = []
    for gap in hidden:
        if merged.is_empty() or gap.x > merged[merged.size() - 1].y + 0.0001:
            merged.append(gap)
        else:
            var previous := merged[merged.size() - 1]
            merged[merged.size() - 1] = Vector2(previous.x, maxf(previous.y, gap.y))
    var visible: Array[Vector2] = []
    var cursor := 0.0
    for gap in merged:
        if gap.x > cursor + 0.0001:
            visible.append(Vector2(cursor, gap.x))
        cursor = maxf(cursor, gap.y)
    if cursor < 0.9999:
        visible.append(Vector2(cursor, 1.0))
    return visible

func _append_compiled_ribbon(a: Vector3, b: Vector3, width: float, interval: Vector2,
        horizontal_length: float, vertices: PackedVector3Array, normals: PackedVector3Array,
        uvs: PackedVector2Array, indices: PackedInt32Array) -> void:
    if interval.y - interval.x <= 0.0001:
        return
    var start := a.lerp(b, interval.x)
    var finish := a.lerp(b, interval.y)
    start.y += WATER_LIFT_M
    finish.y += WATER_LIFT_M
    var tangent := Vector2(finish.x - start.x, finish.z - start.z)
    if tangent.length_squared() < 0.0001:
        return
    tangent = tangent.normalized()
    var side := Vector2(-tangent.y, tangent.x) * width * 0.5
    var base := vertices.size()
    vertices.append(Vector3(start.x + side.x, start.y, start.z + side.y))
    vertices.append(Vector3(start.x - side.x, start.y, start.z - side.y))
    vertices.append(Vector3(finish.x + side.x, finish.y, finish.z + side.y))
    vertices.append(Vector3(finish.x - side.x, finish.y, finish.z - side.y))
    for _index in range(4):
        normals.append(Vector3.UP)
    var v0 := horizontal_length * interval.x / UV_METRES_PER_REPEAT
    var v1 := horizontal_length * interval.y / UV_METRES_PER_REPEAT
    uvs.append(Vector2(0.0, v0))
    uvs.append(Vector2(1.0, v0))
    uvs.append(Vector2(0.0, v1))
    uvs.append(Vector2(1.0, v1))
    indices.append_array(PackedInt32Array([base, base + 2, base + 1, base + 1, base + 2, base + 3]))

func _append_ribbon_part(raw_part: Array, width: float, tile_world_x: float, tile_world_z: float,
        vertices: PackedVector3Array, normals: PackedVector3Array, uvs: PackedVector2Array, indices: PackedInt32Array) -> void:
    var points: Array[Vector3] = []
    for raw_point in raw_part:
        if not raw_point is Array or raw_point.size() < 2:
            continue
        var local_x := float(raw_point[0])
        var local_z := float(raw_point[1])
        var world_x := tile_world_x + local_x
        var world_z := tile_world_z + local_z
        var elevation := float(terrain.height_at(world_x, world_z))
        if not is_finite(elevation):
            return
        points.append(Vector3(local_x, elevation + WATER_LIFT_M, local_z))
    if points.size() < 2:
        return
    var base := vertices.size()
    var distance := 0.0
    var half_width := width * 0.5
    for i in range(points.size()):
        var prev: Vector3 = points[maxi(i - 1, 0)]
        var current: Vector3 = points[i]
        var next: Vector3 = points[mini(i + 1, points.size() - 1)]
        var tangent := Vector2(next.x - prev.x, next.z - prev.z)
        if tangent.length_squared() < 0.0001:
            tangent = Vector2(0.0, 1.0)
        tangent = tangent.normalized()
        var side := Vector2(-tangent.y, tangent.x) * half_width
        if i > 0:
            var segment := Vector2(current.x - points[i - 1].x, current.z - points[i - 1].z)
            distance += segment.length()
        vertices.append(Vector3(current.x + side.x, current.y, current.z + side.y))
        vertices.append(Vector3(current.x - side.x, current.y, current.z - side.y))
        normals.append(Vector3.UP)
        normals.append(Vector3.UP)
        var v := distance / UV_METRES_PER_REPEAT
        uvs.append(Vector2(0.0, v))
        uvs.append(Vector2(1.0, v))
    for i in range(points.size() - 1):
        var a := base + i * 2
        var b := a + 1
        var c := a + 2
        var d := a + 3
        indices.append_array(PackedInt32Array([a, c, b, b, c, d]))

func _finite_vector(value: Vector3) -> bool:
    return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)

func _reposition_loaded() -> void:
    for key in _loaded.keys():
        var node = _loaded[key]
        if not is_instance_valid(node):
            continue
        var tile := _parse_tile_key(str(key))
        node.position = coordinates.world_to_local(float(tile.x) * tile_size, float(tile.y) * tile_size, 0.0)

func _tile_key(x: int, z: int) -> String:
    return "%d:%d" % [x, z]

func _parse_tile_key(key: String) -> Vector2i:
    var parts := key.split(":")
    if parts.size() != 2:
        return Vector2i.ZERO
    return Vector2i(int(parts[0]), int(parts[1]))