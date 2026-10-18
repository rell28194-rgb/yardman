extends SceneTree

const Probe = preload("res://scripts/gpu_roadside_shared_probe.gd")
const Lifecycle = preload("res://scripts/gpu_indirect_multimesh_lifecycle.gd")
const Budget = preload("res://scripts/gpu_indirect_budget.gd")
const PROBE_COUNT := 1027
const SURFACE_COUNT := 2
const DESTINATION_STRIDE_FLOATS := 20
const TIMEOUT_FRAMES := 240
const CLEANUP_TIMEOUT_FRAMES := 120

var failures := 0
var _mesh: ArrayMesh
var _cleanup_mutex := Mutex.new()
var _cleanup_done := false
var _cleanup_manual_frees := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("GPU_ROADSIDE_SHARED_TEST: " + message)

func _make_two_surface_mesh() -> ArrayMesh:
    var mesh := ArrayMesh.new()
    var first := []
    first.resize(Mesh.ARRAY_MAX)
    first[Mesh.ARRAY_VERTEX] = PackedVector3Array([
        Vector3(-0.5, 0.0, 0.0), Vector3(0.5, 0.0, 0.0), Vector3(0.0, 1.0, 0.0)])
    first[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, first)
    var second := []
    second.resize(Mesh.ARRAY_MAX)
    second[Mesh.ARRAY_VERTEX] = PackedVector3Array([
        Vector3(-0.5, 0.0, 0.1), Vector3(0.0, 1.0, 0.1), Vector3(0.5, 0.0, 0.1)])
    second[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, second)
    return mesh

func _make_multimesh() -> RID:
    var rid := RenderingServer.multimesh_create()
    RenderingServer.multimesh_allocate_data(rid, PROBE_COUNT,
        RenderingServer.MULTIMESH_TRANSFORM_3D, true, true, true)
    RenderingServer.multimesh_set_mesh(rid, _mesh.get_rid())
    RenderingServer.multimesh_set_custom_aabb(rid,
        AABB(Vector3(-60.0, -20.0, -60.0), Vector3(120.0, 40.0, 120.0)))
    return rid

func _run() -> void:
    _mesh = _make_two_surface_mesh()
    var near_multimesh := _make_multimesh()
    var far_multimesh := _make_multimesh()
    var grass_multimesh := _make_multimesh()
    var multimeshes := [near_multimesh, far_multimesh, grass_multimesh]

    var probe := Probe.new()
    _check(probe.begin(near_multimesh, far_multimesh, grass_multimesh,
        PROBE_COUNT, SURFACE_COUNT), "packed roadside probe did not start")
    var frames := 0
    while not probe.is_done() and frames < TIMEOUT_FRAMES:
        frames += 1
        await process_frame
    _check(probe.is_done(), "packed roadside probe timed out")

    var result := probe.result()
    _check(bool(result.get("supported", false)),
        "packed roadside path unavailable: " + str(result.get("reason", "unknown")))
    if bool(result.get("supported", false)):
        _check(int(result.get("source_stride_floats", 0)) == Budget.PACKED_ROADSIDE_SOURCE_FLOATS,
            "packed source is not two vec4 records")
        _check(int(result.get("source_bytes", -1)) == PROBE_COUNT * Budget.PACKED_ROADSIDE_SOURCE_BYTES,
            "packed source allocation exceeds 32 bytes per anchor")
        _check(int(result.get("destination_stride_floats", 0)) == DESTINATION_STRIDE_FLOATS,
            "destination no longer matches Transform3D+color+custom layout")

        var expected := _expected_sets()
        _validate_layer("near", result, expected.near, 1.0)
        _validate_layer("far", result, expected.far, 1.0)
        _validate_layer("grass", result, expected.grass, 1.2)
        print("YARDMAN_GPU_ROADSIDE_SHARED_METRICS count=%d near=%d far=%d grass=%d source_bpi=%d roundtrip_us=%d" % [
            PROBE_COUNT, int(result.near_count), int(result.far_count), int(result.grass_count),
            int(result.source_bytes) / PROBE_COUNT, int(result.roundtrip_us)])

    await _cleanup_multimeshes(multimeshes)
    if Lifecycle.requires_472_command_buffer_workaround():
        _check(_cleanup_manual_frees == multimeshes.size(),
            "Godot 4.7.2 workaround did not free every roadside command buffer")
    _mesh = null
    await process_frame
    print("YARDMAN_GPU_ROADSIDE_SHARED_TEST %s packed32=1 shared_source=1 near_far_grass=1 custom_parity=1 multsurface=1 cleanup=1" % (
        "PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)

func _expected_sets() -> Dictionary:
    var result := {"near": {}, "far": {}, "grass": {}}
    for index in range(PROBE_COUNT):
        var source := Probe.source_record(index, PROBE_COUNT)
        var position := Vector3(source[0], source[1], source[2])
        var scale := source[4]
        var radius := maxf(0.25, scale * 2.0)
        var visible := position.x + 50.0 >= -radius and -position.x + 50.0 >= -radius \
            and position.y + 50.0 >= -radius and -position.y + 50.0 >= -radius \
            and position.z + 50.0 >= -radius and -position.z + 50.0 >= -radius
        if not visible:
            continue
        var distance_xz := Vector2(position.x, position.z).length()
        if distance_xz <= Probe.NEAR_END:
            result.near[index] = true
        if distance_xz >= Probe.FAR_BEGIN and distance_xz <= Probe.FAR_END:
            result.far[index] = true
        if distance_xz <= Probe.GRASS_END:
            result.grass[index] = true
    return result

func _validate_layer(layer: String, result: Dictionary, expected_ids: Dictionary,
        scale_multiplier: float) -> void:
    var count := int(result.get(layer + "_count", -1))
    var records: PackedFloat32Array = result.get(layer + "_records", PackedFloat32Array())
    var commands: PackedInt32Array = result.get(layer + "_commands", PackedInt32Array())
    _check(count == expected_ids.size(), "%s visible count differs from CPU reference" % layer)
    _check(records.size() == count * DESTINATION_STRIDE_FLOATS,
        "%s full-record output size differs from count" % layer)
    _check(commands.size() >= SURFACE_COUNT * 5,
        "%s command buffer is too small for all surfaces" % layer)
    if commands.size() >= SURFACE_COUNT * 5:
        for surface in range(SURFACE_COUNT):
            _check(commands[surface * 5 + 1] == count,
                "%s surface %d indirect count differs" % [layer, surface])

    var seen: Dictionary = {}
    if records.size() != count * DESTINATION_STRIDE_FLOATS:
        return
    for slot in range(count):
        var base := slot * DESTINATION_STRIDE_FLOATS
        var source_id := int(round(records[base + 16] * float(PROBE_COUNT - 1)))
        _check(expected_ids.has(source_id),
            "%s contains source outside its visibility/range set" % layer)
        _check(not seen.has(source_id), "%s duplicated a source anchor" % layer)
        seen[source_id] = true
        if expected_ids.has(source_id):
            var expected_record := _expected_record(source_id, layer, scale_multiplier)
            for component in range(DESTINATION_STRIDE_FLOATS):
                _check(absf(records[base + component] - expected_record[component]) < 0.00035,
                    "%s source %d component %d changed during packed expansion" % [layer, source_id, component])
    _check(seen.size() == expected_ids.size(), "%s omitted visible anchors" % layer)

func _expected_record(index: int, _layer: String, scale_multiplier: float) -> PackedFloat32Array:
    var source := Probe.source_record(index, PROBE_COUNT)
    var position := Vector3(source[0], source[1], source[2])
    var yaw := source[3]
    var scale := source[4] * scale_multiplier
    var basis := Basis(Vector3.UP, yaw).scaled(Vector3.ONE * scale)
    return PackedFloat32Array([
        basis.x.x, basis.y.x, basis.z.x, position.x,
        basis.x.y, basis.y.y, basis.z.y, position.y,
        basis.x.z, basis.y.z, basis.z.z, position.z,
        1.0, 1.0, 1.0, 1.0,
        source[5], source[6], source[7], 1.0,
    ])

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
    _check(_cleanup_is_done(), "render-thread roadside cleanup timed out")
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
