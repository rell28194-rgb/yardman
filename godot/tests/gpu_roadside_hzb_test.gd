extends SceneTree

const Probe = preload("res://scripts/gpu_roadside_hzb_probe.gd")
const Shared = preload("res://scripts/gpu_roadside_shared_probe.gd")
const Lifecycle = preload("res://scripts/gpu_indirect_multimesh_lifecycle.gd")
const COUNT := 1027
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
        push_error("GPU_ROADSIDE_HZB_TEST: " + message)

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
    RenderingServer.multimesh_allocate_data(rid, COUNT,
        RenderingServer.MULTIMESH_TRANSFORM_3D, true, true, true)
    RenderingServer.multimesh_set_mesh(rid, _mesh.get_rid())
    RenderingServer.multimesh_set_custom_aabb(rid,
        AABB(Vector3(-100.0, -40.0, -100.0), Vector3(200.0, 80.0, 200.0)))
    return rid

func _run() -> void:
    _mesh = _make_two_surface_mesh()
    var near_multimesh := _make_multimesh()
    var far_multimesh := _make_multimesh()
    var grass_multimesh := _make_multimesh()
    var multimeshes := [near_multimesh, far_multimesh, grass_multimesh]

    var probe := Probe.new()
    _check(probe.begin(near_multimesh, far_multimesh, grass_multimesh,
        COUNT, SURFACE_COUNT), "roadside HZB probe did not start")
    var frames := 0
    while not probe.is_done() and frames < TIMEOUT_FRAMES:
        frames += 1
        await process_frame
    _check(probe.is_done(), "roadside HZB probe timed out")

    var result := probe.result()
    _check(bool(result.get("supported", false)),
        "roadside HZB path unavailable: " + str(result.get("reason", "unknown")))
    if bool(result.get("supported", false)):
        _validate_result(result)

    await _cleanup_multimeshes(multimeshes)
    if Lifecycle.requires_472_command_buffer_workaround():
        _check(_cleanup_manual_frees == multimeshes.size(),
            "Godot 4.7.2 workaround did not free every roadside command buffer")
    _mesh = null
    await process_frame
    print("YARDMAN_GPU_ROADSIDE_HZB_TEST %s zero_false_occlusion=1 gpu_chain=1 near_far_grass=1 multsurface=1 cleanup=1" % (
        "PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)

func _validate_result(result: Dictionary) -> void:
    var base_depth: PackedFloat32Array = result.get("base_depth", PackedFloat32Array())
    var candidates: PackedFloat32Array = result.get("candidates", PackedFloat32Array())
    var visibility: PackedInt32Array = result.get("visibility", PackedInt32Array())
    _check(base_depth.size() == Probe.WIDTH * Probe.HEIGHT,
        "base depth field size changed")
    _check(candidates.size() == COUNT * Probe.CANDIDATE_STRIDE_FLOATS,
        "projected roadside candidate count changed")
    _check(visibility.size() == COUNT, "GPU visibility flag count changed")
    if base_depth.size() != Probe.WIDTH * Probe.HEIGHT \
            or candidates.size() != COUNT * Probe.CANDIDATE_STRIDE_FLOATS \
            or visibility.size() != COUNT:
        return

    var truth_occluded := 0
    var gpu_occluded := 0
    var false_occlusions := 0
    var misses := 0
    for index in range(COUNT):
        var base := index * Probe.CANDIDATE_STRIDE_FLOATS
        var candidate := PackedFloat32Array([
            candidates[base + 0], candidates[base + 1], candidates[base + 2],
            candidates[base + 3], candidates[base + 4]])
        var truth_visible := Probe.brute_visible(candidate, base_depth)
        var gpu_visible := visibility[index] != 0
        if not truth_visible:
            truth_occluded += 1
        if not gpu_visible:
            gpu_occluded += 1
        if not gpu_visible and truth_visible:
            false_occlusions += 1
        if gpu_visible and not truth_visible:
            misses += 1

    _check(truth_occluded > 0, "oracle produced no definitely occluded roadside anchors")
    _check(gpu_occluded > 0, "HZB rejected no roadside anchors")
    _check(false_occlusions == 0,
        "HZB produced false roadside occlusions: %d" % false_occlusions)
    var efficiency := float(gpu_occluded) / float(maxi(truth_occluded, 1))
    _check(efficiency >= 0.35,
        "HZB roadside culling efficiency fell below 35%%: %.4f" % efficiency)

    var expected := _expected_sets(visibility)
    var baseline := _expected_sets(PackedInt32Array())
    _validate_layer("near", result, expected.near)
    _validate_layer("far", result, expected.far)
    _validate_layer("grass", result, expected.grass)
    var baseline_total := baseline.near.size() + baseline.far.size() + baseline.grass.size()
    var hzb_total := expected.near.size() + expected.far.size() + expected.grass.size()
    _check(hzb_total < baseline_total,
        "HZB did not reduce the roadside indirect working set")

    print("YARDMAN_GPU_ROADSIDE_HZB_METRICS candidates=%d truth_occluded=%d gpu_occluded=%d misses=%d false_occlusions=%d efficiency=%.4f baseline_instances=%d hzb_instances=%d near=%d far=%d grass=%d pyramid_bytes=%d roundtrip_us=%d" % [
        COUNT, truth_occluded, gpu_occluded, misses, false_occlusions, efficiency,
        baseline_total, hzb_total, int(result.near_count), int(result.far_count),
        int(result.grass_count), int(result.pyramid_bytes), int(result.roundtrip_us)])

func _expected_sets(visibility: PackedInt32Array) -> Dictionary:
    var result := {"near": {}, "far": {}, "grass": {}}
    var planes := Probe.camera_planes()
    for index in range(COUNT):
        if visibility.size() == COUNT and visibility[index] == 0:
            continue
        var source := Shared.source_record(index, COUNT)
        var position := Vector3(source[0], source[1], source[2])
        var scale := source[4]
        var radius := maxf(0.25, scale * 2.0)
        if not Shared.sphere_visible(position, radius, planes):
            continue
        var distance_xz := Vector2(position.x - Probe.CAMERA_POSITION.x,
            position.z - Probe.CAMERA_POSITION.z).length()
        if distance_xz <= Shared.NEAR_END:
            result.near[index] = true
        if distance_xz >= Shared.FAR_BEGIN and distance_xz <= Shared.FAR_END:
            result.far[index] = true
        if distance_xz <= Shared.GRASS_END:
            result.grass[index] = true
    return result

func _validate_layer(layer: String, result: Dictionary, expected_ids: Dictionary) -> void:
    var count := int(result.get(layer + "_count", -1))
    var records: PackedFloat32Array = result.get(layer + "_records", PackedFloat32Array())
    var commands: PackedInt32Array = result.get(layer + "_commands", PackedInt32Array())
    _check(count == expected_ids.size(),
        "%s indirect count differs from HZB+frustum CPU reference" % layer)
    _check(records.size() == count * DESTINATION_STRIDE_FLOATS,
        "%s compacted record size differs from indirect count" % layer)
    _check(commands.size() >= SURFACE_COUNT * 5,
        "%s command buffer is too small for all surfaces" % layer)
    if commands.size() >= SURFACE_COUNT * 5:
        for surface in range(SURFACE_COUNT):
            _check(commands[surface * 5 + 1] == count,
                "%s surface %d indirect count differs" % [layer, surface])

    if records.size() != count * DESTINATION_STRIDE_FLOATS:
        return
    var seen: Dictionary = {}
    for slot in range(count):
        var base := slot * DESTINATION_STRIDE_FLOATS
        var source_id := int(round(records[base + 16] * float(COUNT - 1)))
        _check(expected_ids.has(source_id),
            "%s contains a source rejected by HZB/frustum/range" % layer)
        _check(not seen.has(source_id), "%s duplicated a source anchor" % layer)
        seen[source_id] = true
    _check(seen.size() == expected_ids.size(), "%s omitted expected visible anchors" % layer)

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
    _check(_cleanup_is_done(), "render-thread roadside HZB cleanup timed out")
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
