extends Node3D
class_name YardmanHydrologyRenderer

const WATER_SHADER = preload("res://shaders/river_surface.gdshader")
const MeshGeometryGuard = preload("res://scripts/mesh_geometry_guard.gd")
const DEFAULT_ACTIVE_RADIUS := 1
const DEFAULT_VERTEX_CAP := 12000
const WATER_LIFT_M := 0.075
const UV_METRES_PER_REPEAT := 8.0
const AUDIO_SEGMENT_CAP_PER_TILE := 96

var terrain
var coordinates
var data_root := ""
var manifest: Dictionary = {}
var tile_size := 4096.0
var active_radius := DEFAULT_ACTIVE_RADIUS
var vertex_cap := DEFAULT_VERTEX_CAP
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
    if not parsed is Dictionary or int(parsed.get("format_version", 0)) != 1:
        return false
    if str(parsed.get("pack_id", "")) != "jamaica_hydrology_osm_v1":
        return false
    if str(parsed.get("crs", "")) != "EPSG:3448":
        return false
    manifest = parsed
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
    if not payload is Dictionary or int(payload.get("format_version", 0)) != 1:
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
    # Audio never needs render-level polyline density. Sample a capped set of
    # canonical 2D segments per loaded tile; at 3x3 tiles this is <=864 tests
    # per 5 Hz proximity update, independent of island-wide waterway count.
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