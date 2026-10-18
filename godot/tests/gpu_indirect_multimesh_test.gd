extends SceneTree

const Probe = preload("res://scripts/gpu_indirect_multimesh_probe.gd")
const Lifecycle = preload("res://scripts/gpu_indirect_multimesh_lifecycle.gd")
const PROBE_COUNT := 8195
const TIMEOUT_FRAMES := 240
const CLEANUP_TIMEOUT_FRAMES := 120
var failures := 0
var _mesh: BoxMesh
var _multimesh := RID()
var _cleanup_mutex := Mutex.new()
var _cleanup_done := false
var _cleanup_result: Dictionary = {}

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("GPU_INDIRECT_MULTIMESH_TEST: " + message)

func _sphere(index: int) -> Vector4:
    return Vector4(float((index * 73) % 401) - 200.0, float((index * 151) % 301) - 150.0,
        float((index * 199) % 501) - 250.0, 0.5 + float(index % 9) * 0.35)

func _visible(sphere: Vector4) -> bool:
    return sphere.x + 50.0 >= -sphere.w and -sphere.x + 50.0 >= -sphere.w \
        and sphere.y + 50.0 >= -sphere.w and -sphere.y + 50.0 >= -sphere.w \
        and sphere.z + 50.0 >= -sphere.w and -sphere.z + 50.0 >= -sphere.w

func _origin_key(origin: Vector3) -> String:
    return "%.3f:%.3f:%.3f" % [origin.x, origin.y, origin.z]

func _run() -> void:
    _mesh = BoxMesh.new()
    _mesh.size = Vector3.ONE
    _multimesh = RenderingServer.multimesh_create()

    # Godot 4.7.2 initializes an indirect command buffer when a mesh is bound
    # after indirect allocation. Binding the mesh first can leave that buffer
    # invalid, so this ordering is a hard contract for Yardman's GPU path.
    RenderingServer.multimesh_allocate_data(_multimesh, PROBE_COUNT,
        RenderingServer.MULTIMESH_TRANSFORM_3D, false, false, true)
    RenderingServer.multimesh_set_mesh(_multimesh, _mesh.get_rid())
    RenderingServer.multimesh_set_custom_aabb(_multimesh, AABB(Vector3(-260, -210, -310), Vector3(520, 420, 620)))

    _check(RenderingServer.multimesh_get_buffer_rd_rid(_multimesh).is_valid(),
        "instance RD buffer did not initialize after indirect allocation")
    _check(RenderingServer.multimesh_get_command_buffer_rd_rid(_multimesh).is_valid(),
        "command RD buffer did not initialize after post-allocation mesh bind")

    var probe := Probe.new()
    _check(probe.begin(_multimesh, PROBE_COUNT), "probe did not start")
    var frames := 0
    while not probe.is_done() and frames < TIMEOUT_FRAMES:
        frames += 1
        await process_frame

    _check(probe.is_done(), "render-thread probe timed out")
    var result := probe.result()
    _check(bool(result.get("supported", false)), "global RD indirect path unavailable: " + str(result.get("reason", "unknown")))
    if bool(result.get("supported", false)):
        _check(bool(result.get("instance_buffer_valid", false)), "MultiMesh instance RD buffer invalid")
        _check(bool(result.get("command_buffer_valid", false)), "MultiMesh indirect command RD buffer invalid")
        var expected: Dictionary = {}
        var expected_count := 0
        for index in range(PROBE_COUNT):
            var sphere := _sphere(index)
            if _visible(sphere):
                expected_count += 1
                var key := _origin_key(Vector3(sphere.x, sphere.y, sphere.z))
                expected[key] = int(expected.get(key, 0)) + 1
        var origins: PackedVector3Array = result.get("origins", PackedVector3Array())
        var actual: Dictionary = {}
        for origin in origins:
            var key := _origin_key(origin)
            actual[key] = int(actual.get(key, 0)) + 1
        _check(int(result.get("visible", -1)) == expected_count, "GPU indirect instanceCount differs from CPU reference")
        _check(origins.size() == expected_count, "GPU compacted MultiMesh transform count differs from CPU reference")
        _check(actual == expected, "GPU-written MultiMesh transforms differ from visible source set")
        print("YARDMAN_GPU_INDIRECT_MULTIMESH_METRICS count=%d visible=%d roundtrip_us=%d" % [PROBE_COUNT, expected_count, int(result.get("roundtrip_us", -1))])

    await _free_multimesh_and_sync()
    if Lifecycle.requires_472_command_buffer_workaround():
        _check(bool(_cleanup_result.get("manual_command_free", false)),
            "Godot 4.7.2 command-buffer leak workaround did not execute")
    _mesh = null
    await process_frame
    print("YARDMAN_GPU_INDIRECT_MULTIMESH_TEST %s global_rd=1 direct_buffer=1 indirect_count=1 init_order=1 cleanup_fence=1 leak_workaround=1 no_runtime_readback=1" % ("PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)

func _free_multimesh_and_sync() -> void:
    if not _multimesh.is_valid():
        return
    var rid_to_free := _multimesh
    _multimesh = RID()
    _cleanup_mutex.lock()
    _cleanup_done = false
    _cleanup_result = {}
    _cleanup_mutex.unlock()
    RenderingServer.call_on_render_thread(_free_multimesh_render_thread.bind(rid_to_free))

    var cleanup_frames := 0
    while not _is_cleanup_done() and cleanup_frames < CLEANUP_TIMEOUT_FRAMES:
        cleanup_frames += 1
        await process_frame
    _check(_is_cleanup_done(), "render-thread MultiMesh cleanup timed out")

    # Test-only fence: ensure deferred GPU destruction completes before the
    # process exits so a leak warning cannot be hidden by shutdown timing.
    RenderingServer.force_sync()
    await process_frame

func _free_multimesh_render_thread(rid_to_free: RID) -> void:
    var result := Lifecycle.free_on_render_thread(rid_to_free)
    _cleanup_mutex.lock()
    _cleanup_result = result
    _cleanup_done = true
    _cleanup_mutex.unlock()

func _is_cleanup_done() -> bool:
    _cleanup_mutex.lock()
    var value := _cleanup_done
    _cleanup_mutex.unlock()
    return value
