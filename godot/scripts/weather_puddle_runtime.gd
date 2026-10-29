extends Node3D
class_name YardmanWeatherPuddleRuntime

const PUDDLE_SHADER = preload("res://shaders/puddle_surface.gdshader")
const MAX_PUDDLES := 28
const QUERY_RADIUS_M := 85.0
const UPDATE_INTERVAL := 0.65
const MIN_WETNESS := 0.28
const QUALITY_CAPS := {
    "Performance": 6,
    "Balanced": 12,
    "Quality": 20,
    "Ultra": 28,
    "Custom": 16,
}

var _batch: MultiMeshInstance3D
var _material: ShaderMaterial
var _clock := 0.0
var _last_visible := 0
var _last_records := 0

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    _build_batch()
    set_process(true)

func _exit_tree() -> void:
    if _batch != null:
        _batch.multimesh = null
        _batch = null

func _process(delta: float) -> void:
    var safe_delta := clampf(delta, 0.0, 0.25) if is_finite(delta) else 0.016
    var weather := get_node_or_null("/root/WeatherFX")
    var wetness := clampf(float(weather.get("_intensity")), 0.0, 1.0) if weather != null else 0.0
    _material.set_shader_parameter("wetness", wetness)
    var game := get_tree().current_scene if get_tree() != null else null
    var reduced_motion := false
    if game != null:
        var touch = game.get("touch")
        if touch != null:
            var settings = touch.get("settings")
            if settings is Dictionary:
                reduced_motion = settings.get("reduced_motion", false) == true
    _material.set_shader_parameter("motion_scale", 0.18 if reduced_motion else 1.0)
    if wetness < MIN_WETNESS or game == null or game.get("world_ready") != true:
        _set_visible(0)
        return
    _clock += safe_delta
    if _clock < UPDATE_INTERVAL:
        return
    _clock = 0.0
    _rebuild_nearby(game, wetness)

func _build_batch() -> void:
    _material = ShaderMaterial.new()
    _material.shader = PUDDLE_SHADER
    _material.set_shader_parameter("wetness", 0.0)
    var mesh := _make_disc_mesh(18)
    mesh.surface_set_material(0, _material)
    var multimesh := MultiMesh.new()
    multimesh.transform_format = MultiMesh.TRANSFORM_3D
    multimesh.use_custom_data = true
    multimesh.mesh = mesh
    multimesh.instance_count = MAX_PUDDLES
    for index in range(MAX_PUDDLES):
        multimesh.set_instance_transform(index, Transform3D(Basis.IDENTITY, Vector3.ZERO))
        var phase := float((index * 37) % 101) / 101.0
        var alpha := 0.78 + float((index * 17) % 19) / 86.0
        multimesh.set_instance_custom_data(index, Color(phase, 0.0, 0.0, alpha))
    multimesh.visible_instance_count = 0
    _batch = MultiMeshInstance3D.new()
    _batch.name = "WeatherPuddleBatch"
    _batch.multimesh = multimesh
    _batch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    _batch.visibility_range_end = 110.0
    _batch.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
    add_child(_batch)

func _make_disc_mesh(segments: int) -> ArrayMesh:
    var count := clampi(segments, 8, 32)
    var vertices := PackedVector3Array([Vector3.ZERO])
    var uvs := PackedVector2Array([Vector2(0.5, 0.5)])
    for index in range(count):
        var angle := TAU * float(index) / float(count)
        vertices.append(Vector3(cos(angle), 0.0, sin(angle)))
        uvs.append(Vector2(0.5 + cos(angle) * 0.5, 0.5 + sin(angle) * 0.5))
    var indices := PackedInt32Array()
    for index in range(count):
        var a := 1 + index
        var b := 1 + ((index + 1) % count)
        indices.append_array(PackedInt32Array([0, b, a]))
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_TEX_UV] = uvs
    arrays[Mesh.ARRAY_INDEX] = indices
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    return mesh

func _rebuild_nearby(game: Node, wetness: float) -> void:
    var roads = game.get("roads")
    var terrain = game.get("terrain")
    var car = game.get("car")
    var player = game.get("player")
    if roads == null or terrain == null or not car is Node3D or not player is Node3D:
        _set_visible(0)
        return
    var coordinates = roads.get("coordinates")
    if coordinates == null:
        _set_visible(0)
        return
    var active: Node3D = car if player.get("in_vehicle") == true else player
    var world: PackedFloat64Array = coordinates.local_to_world(active.position)
    if world.size() < 3:
        _set_visible(0)
        return
    var records = roads.call("_nearby_surface_segments", float(world[0]), float(world[2]), QUERY_RADIUS_M)
    if not records is Dictionary:
        _set_visible(0)
        return
    _last_records = records.size()
    var quality := "Balanced"
    var visuals = game.get("visuals")
    if visuals != null:
        quality = str(visuals.get("quality"))
    var cap := clampi(int(QUALITY_CAPS.get(quality, QUALITY_CAPS.Balanced)), 0, MAX_PUDDLES)
    var candidates := build_candidates(records, Vector2(float(world[0]), float(world[2])), QUERY_RADIUS_M, cap)
    var written := 0
    for candidate: Dictionary in candidates:
        if written >= cap:
            break
        var point: Vector2 = candidate.point
        var heading := float(candidate.heading)
        var direction := Vector2(-sin(heading), -cos(heading)).normalized()
        if direction.length_squared() < 0.5:
            direction = Vector2(0.0, 1.0)
        var sample := direction * 1.5
        var center_height := float(terrain.height_at(point.x, point.y))
        var before_height := float(terrain.height_at(point.x - sample.x, point.y - sample.y))
        var after_height := float(terrain.height_at(point.x + sample.x, point.y + sample.y))
        if not is_finite(center_height) or not is_finite(before_height) or not is_finite(after_height):
            continue
        var grade := absf(after_height - before_height) / 3.0
        if grade > 0.085:
            continue
        var local: Vector3 = coordinates.world_to_local(point.x, point.y, center_height + 0.185)
        var length_scale := float(candidate.length_scale)
        var width_scale := float(candidate.width_scale)
        var basis := Basis(Vector3.UP, heading).scaled(Vector3(length_scale, 1.0, width_scale))
        _batch.multimesh.set_instance_transform(written, Transform3D(basis, local))
        var phase := float(candidate.phase)
        var alpha := lerpf(0.80, 1.0, wetness)
        _batch.multimesh.set_instance_custom_data(written, Color(phase, grade, 0.0, alpha))
        written += 1
    _set_visible(written)

func _set_visible(count: int) -> void:
    _last_visible = clampi(count, 0, MAX_PUDDLES)
    if _batch != null and _batch.multimesh != null:
        _batch.multimesh.visible_instance_count = _last_visible
        _batch.visible = _last_visible > 0

func debug_state() -> Dictionary:
    return {
        "batches": 1 if _batch != null else 0,
        "max_puddles": MAX_PUDDLES,
        "visible": _last_visible,
        "records_seen": _last_records,
        "query_radius_m": QUERY_RADIUS_M,
    }

static func build_candidates(records: Dictionary, center: Vector2, radius: float, max_count: int) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    if not is_finite(center.x) or not is_finite(center.y) or not is_finite(radius) or radius <= 0.0 or max_count <= 0:
        return result
    var identifiers: Array = records.keys()
    identifiers.sort()
    for raw_identifier in identifiers:
        var identifier := str(raw_identifier)
        var raw_record = records[raw_identifier]
        if not raw_record is Dictionary:
            continue
        var record: Dictionary = raw_record
        var a: Vector2 = record.get("a", Vector2.ZERO)
        var b: Vector2 = record.get("b", Vector2.ZERO)
        var width := clampf(float(record.get("width_m", 4.0)), 1.5, 24.0)
        var delta := b - a
        var length := delta.length()
        if length < 4.0:
            continue
        var tangent := delta / length
        var normal := Vector2(-tangent.y, tangent.x)
        var slots := 2 if length >= 36.0 else 1
        for slot in range(slots):
            var hash_value := absi((identifier + ":puddle:" + str(slot)).hash())
            var fraction_noise := float(hash_value % 1000) / 999.0
            var fraction := lerpf(0.18, 0.82, fraction_noise)
            if slots == 2:
                fraction = lerpf(0.22, 0.43, fraction_noise) if slot == 0 else lerpf(0.57, 0.80, fraction_noise)
            var centerline := a + delta * fraction
            if centerline.distance_squared_to(center) > radius * radius:
                continue
            var lateral_noise := float((hash_value / 1009) % 1000) / 999.0 * 2.0 - 1.0
            var lateral_limit := maxf(0.15, width * 0.27)
            var point := centerline + normal * lateral_noise * lateral_limit
            var length_scale := 0.75 + float((hash_value / 7919) % 1000) / 999.0 * 1.15
            var width_scale := 0.32 + float((hash_value / 1543) % 1000) / 999.0 * 0.62
            var heading := atan2(-tangent.x, -tangent.y)
            result.append({
                "identifier": identifier,
                "point": point,
                "heading": heading,
                "length_scale": length_scale,
                "width_scale": width_scale,
                "phase": float(hash_value % 4093) / 4093.0,
                "distance_squared": point.distance_squared_to(center),
                "half_road_width": width * 0.5,
                "centerline": centerline,
            })
    result.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
        var ld := float(left.distance_squared)
        var rd := float(right.distance_squared)
        if not is_equal_approx(ld, rd):
            return ld < rd
        return str(left.identifier) < str(right.identifier))
    if result.size() > max_count:
        result.resize(max_count)
    return result
