extends SceneTree

const Probe = preload("res://scripts/gpu_roadside_shared_probe.gd")
const Lifecycle = preload("res://scripts/gpu_indirect_multimesh_lifecycle.gd")
const PROBE_COUNT := 1027
const SURFACE_COUNT := 1
const DESTINATION_STRIDE_FLOATS := 20
const TIMEOUT_FRAMES := 240
const CLEANUP_TIMEOUT_FRAMES := 120
const FOV_Y := 78.0
const ASPECT := 16.0 / 9.0
const NEAR_M := 1.0
const FAR_M := 72.0

var failures := 0
var _mesh: ArrayMesh
var _cleanup_mutex := Mutex.new()
var _cleanup_done := false
var _cleanup_manual_frees := 0
var _camera_transform := Transform3D.IDENTITY
var _camera_position := Vector3.ZERO

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("GPU_ROADSIDE_FRUSTUM_TEST: " + message)

func _make_mesh() -> ArrayMesh:
    var mesh := ArrayMesh.new()
    var arrays := []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
        Vector3(-0.5, 0.0, 0.0), Vector3(0.5, 0.0, 0.0), Vector3(0.0, 1.0, 0.0)])
    arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    return mesh

func _make_multimesh() -> RID:
    var rid := RenderingServer.multimesh_create()
    RenderingServer.multimesh_allocate_data(rid, PROBE_COUNT,
        RenderingServer.MULTIMESH_TRANSFORM_3D, true, true, true)
    RenderingServer.multimesh_set_mesh(rid, _mesh.get_rid())
    RenderingServer.multimesh_set_custom_aabb(rid,
        AABB(Vector3(-70.0, -30.0, -70.0), Vector3(140.0, 60.0, 140.0)))
    return rid

func _run() -> void:
    _mesh = _make_mesh()
    var near_multimesh := _make_multimesh()
    var far_multimesh := _make_multimesh()
    var grass_multimesh := _make_multimesh()
    var multimeshes := [near_multimesh, far_multimesh, grass_multimesh]

    _camera_transform = Transform3D(
        Basis(Vector3.UP, deg_to_rad(28.0)), Vector3(5.0, 1.5, 8.0))
    _camera_position = _camera_transform.origin
    var planes := Probe.perspective_frustum(_camera_transform, FOV_Y, ASPECT, NEAR_M, FAR_M)
    _check(planes.size() == Probe.FRUSTUM_PLANE_COUNT,
        "perspective helper did not produce six planes")

    var probe := Probe.new()
    _check(probe.begin_frustum(near_multimesh, far_multimesh, grass_multimesh,
        PROBE_COUNT, SURFACE_COUNT, _camera_position, planes),
        "real-camera roadside probe did not start")
    var frames := 0
    while not probe.is_done() and frames < TIMEOUT_FRAMES:
        frames += 1
        await process_frame
    _check(probe.is_done(), "real-camera roadside probe timed out")

    var result := probe.result()
    _check(bool(result.get("supported", false)),
        "real-camera roadside path unavailable: " + str(result.get("reason", "unknown")))
    if bool(result.get("supported", false)):
        _check(int(result.get("camera_param_floats", 0)) == Probe.CAMERA_PARAM_FLOATS,
            "camera/frustum buffer does not contain camera plus six planes")
        var expected := _expected_sets()
        _check(expected.visible_total > 0 and expected.visible_total < PROBE_COUNT,
            "test camera did not produce a non-trivial frustum set")
        _validate_layer("near", result, expected.near, 1.0)
        _validate_layer("far", result, expected.far, 1.0)
        _validate_layer("grass", result, expected.grass, 1.2)
        print("YARDMAN_GPU_ROADSIDE_FRUSTUM_METRICS count=%d frustum=%d near=%d far=%d grass=%d roundtrip_us=%d" % [
            PROBE_COUNT, int(expected.visible_total), int(result.near_count),
            int(result.far_count), int(result.grass_count), int(result.roundtrip_us)])

    await _cleanup_multimeshes(multimeshes)
    if Lifecycle.requires_472_command_buffer_workaround():
        _check(_cleanup_manual_frees == multimeshes.size(),
            "Godot 4.7.2 workaround did not free every frustum-test command buffer")
    _mesh = null
    await process_frame
    print("YARDMAN_GPU_ROADSIDE_FRUSTUM_TEST %s real_frustum=1 rotated_camera=1 camera_relative=1 cpu_parity=1 cleanup=1" % (
        "PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)

func _expected_sets() -> Dictionary:
    var result := {"near": {}, "far": {}, "grass": {}, "visible_total": 0}
    var inverse_camera := _camera_transform.affine_inverse()
    var tan_y := tan(deg_to_rad(FOV_Y) * 0.5)
    var tan_x := tan_y * ASPECT
    var local_planes := [
        _normalize_plane(Vector4(0.0, 0.0, -1.0, -NEAR_M)),
        _normalize_plane(Vector4(0.0, 0.0, 1.0, FAR_M)),
        _normalize_plane(Vector4(1.0, 0.0, -tan_x, 0.0)),
        _normalize_plane(Vector4(-1.0, 0.0, -tan_x, 0.0)),
        _normalize_plane(Vector4(0.0, -1.0, -tan_y, 0.0)),
        _normalize_plane(Vector4(0.0, 1.0, -tan_y, 0.0)),
    ]
    for index in range(PROBE_COUNT):
        var source := Probe.source_record(index, PROBE_COUNT)
        var world_position := Vector3(source[0], source[1], source[2])
        var local_position := inverse_camera * world_position
        var radius := maxf(0.25, float(source[4]) * 2.0)
        if not _local_sphere_visible(local_position, radius, local_planes):
            continue
        result.visible_total = int(result.visible_total) + 1
        var distance_xz := Vector2(
            world_position.x - _camera_position.x,
            world_position.z - _camera_position.z).length()
        if distance_xz <= Probe.NEAR_END:
            result.near[index] = true
        if distance_xz >= Probe.FAR_BEGIN and distance_xz <= Probe.FAR_END:
            result.far[index] = true
        if distance_xz <= Probe.GRASS_END:
            result.grass[index] = true
    return result

func _normalize_plane(value: Vector4) -> Vector4:
    var normal := Vector3(value.x, value.y, value.z)
    var length := normal.length()
    return value / length

func _local_sphere_visible(position: Vector3, radius: float, planes: Array) -> bool:
    for plane_value: Vector4 in planes:
        var normal := Vector3(plane_value.x, plane_value.y, plane_value.z)
        if normal.dot(position) + plane_value.w < -radius:
            return false
    return true

func _validate_layer(layer: String, result: Dictionary, expected_ids: Dictionary,
        scale_multiplier: float) -> void:
    var count := int(result.get(layer + "_count", -1))
    var records: PackedFloat32Array = result.get(layer + "_records", PackedFloat32Array())
    var commands: PackedInt32Array = result.get(layer + "_commands", PackedInt32Array())
    _check(count == expected_ids.size(), "%s visible count differs from independent CPU camera reference" % layer)
    _check(records.size() == count * DESTINATION_STRIDE_FLOATS,
        "%s output size differs from indirect count" % layer)
    _check(commands.size() >= 5, "%s command buffer missing surface command" % layer)
    if commands.size() >= 5:
        _check(commands[1] == count, "%s indirect instance count differs" % layer)

    var seen: Dictionary = {}
    if records.size() != count * DESTINATION_STRIDE_FLOATS:
        return
    for slot in range(count):
        var base := slot * DESTINATION_STRIDE_FLOATS
        var source_id := int(round(records[base + 16] * float(PROBE_COUNT - 1)))
        _check(expected_ids.has(source_id),
            "%s contains anchor outside real-camera reference set" % layer)
        _check(not seen.has(source_id), "%s duplicated source anchor" % layer)
        seen[source_id] = true
        if expected_ids.has(source_id):
            var source := Probe.source_record(source_id, PROBE_COUNT)
            _check(absf(records[base + 18] - source[7]) < 0.00035,
                "%s changed custom-data dryness during frustum compaction" % layer)
            var expected_scale := float(source[4]) * scale_multiplier
            var actual_scale := Vector3(records[base + 0], records[base + 1], records[base + 2]).length()
            _check(absf(actual_scale - expected_scale) < 0.00035,
                "%s changed anchor scale during frustum compaction" % layer)
    _check(seen.size() == expected_ids.size(), "%s omitted real-camera visible anchors" % layer)

func _cleanup_multimeshes(multimeshes: Array) -> void:
    _cleanup_mutex.lock()
    _cleanup_done = false
    _cleanup_manual_frees = 0
    _cleanup_mutex.unlock()
    RenderingServer.call_on_render_thread(_cleanup_render_thread.bind(multimeshes))
    var frames := 0
    while not _cleanup_is_done() and frames < CLEANUP_TIMEOUT_FRAMES:
        frames += 1
        await process_frame
    _check(_cleanup_is_done(), "render-thread frustum MultiMesh cleanup timed out")
    RenderingServer.force_sync()
    await process_frame

func _cleanup_render_thread(multimeshes: Array) -> void:
    var manual_frees := 0
    for multimesh in multimeshes:
        var cleanup := Lifecycle.free_on_render_thread(multimesh)
        if bool(cleanup.get("manual_command_free", false)):
            manual_frees += 1
    _cleanup_mutex.lock()
    _cleanup_manual_frees = manual_frees
    _cleanup_done = true
    _cleanup_mutex.unlock()

func _cleanup_is_done() -> bool:
    _cleanup_mutex.lock()
    var value := _cleanup_done
    _cleanup_mutex.unlock()
    return value
