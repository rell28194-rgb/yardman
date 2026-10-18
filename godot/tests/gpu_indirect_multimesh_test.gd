extends SceneTree

const Probe = preload("res://scripts/gpu_indirect_multimesh_probe.gd")
const PROBE_COUNT := 8195
const TIMEOUT_FRAMES := 240
var failures := 0
var _mesh: BoxMesh
var _multimesh := RID()

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
    RenderingServer.multimesh_set_mesh(_multimesh, _mesh.get_rid())
    RenderingServer.multimesh_allocate_data(_multimesh, PROBE_COUNT,
        RenderingServer.MULTIMESH_TRANSFORM_3D, false, false, true)
    RenderingServer.multimesh_set_custom_aabb(_multimesh, AABB(Vector3(-260, -210, -310), Vector3(520, 420, 620)))

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

    if _multimesh.is_valid(): RenderingServer.free_rid(_multimesh)
    _multimesh = RID()
    _mesh = null
    await process_frame
    print("YARDMAN_GPU_INDIRECT_MULTIMESH_TEST %s global_rd=1 direct_buffer=1 indirect_count=1 no_runtime_readback=1" % ("PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)
