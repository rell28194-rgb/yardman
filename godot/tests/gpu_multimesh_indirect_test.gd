extends SceneTree

const SHADER_PATH := "res://shaders/gpu_multimesh_indirect.glsl"
const INSTANCE_COUNT := 8195
const LOCAL_SIZE_X := 64
const TIMEOUT_MS := 8000

var _dispatch_recorded := false
var _readback_done := false
var _result: Dictionary = {}
var _sphere_bytes := PackedByteArray()
var _plane_bytes := PackedByteArray()
var _params_bytes := PackedByteArray()
var _spirv: RDShaderSPIRV
var _mm_buffer := RID()
var _command_buffer := RID()
var _multimesh := RID()
var _mesh: BoxMesh

# RIDs created on the global RenderingDevice must live until a later render
# frame has consumed the recorded compute list. They are released during the
# readback callback, never immediately after compute_list_end().
var _shader := RID()
var _sphere_buffer := RID()
var _plane_buffer := RID()
var _params_buffer := RID()
var _uniform_set := RID()
var _pipeline := RID()
var _record_us := 0

func _initialize() -> void:
    call_deferred("_run")

func _run() -> void:
    _prepare_inputs()
    var shader_file := load(SHADER_PATH) as RDShaderFile
    if shader_file == null:
        await _finish_failure("shader resource unavailable")
        return
    _spirv = shader_file.get_spirv()

    _mesh = BoxMesh.new()
    _mesh.size = Vector3(0.25, 0.25, 0.25)
    _multimesh = RenderingServer.multimesh_create()
    RenderingServer.multimesh_allocate_data(
        _multimesh, INSTANCE_COUNT, RenderingServer.MULTIMESH_TRANSFORM_3D,
        false, false, true)
    RenderingServer.multimesh_set_mesh(_multimesh, _mesh.get_rid())

    # Allow RenderingServer to realize the MultiMesh and indirect buffers.
    for _frame in range(2):
        await process_frame
    _mm_buffer = RenderingServer.multimesh_get_buffer_rd_rid(_multimesh)
    _command_buffer = RenderingServer.multimesh_get_command_buffer_rd_rid(_multimesh)
    if not _mm_buffer.is_valid() or not _command_buffer.is_valid():
        await _finish_failure("RenderingServer did not expose GPU MultiMesh buffers")
        return

    RenderingServer.call_on_render_thread(Callable(self, "_render_thread_dispatch"))
    var started := Time.get_ticks_msec()
    while not _dispatch_recorded and Time.get_ticks_msec() - started < TIMEOUT_MS:
        await process_frame
    if not _dispatch_recorded:
        await _finish_failure("render-thread compute dispatch timed out")
        return

    # Global RenderingDevice command lists are submitted by the engine render
    # loop. submit()/sync() are local-device-only APIs. force_sync() is used
    # solely in this correctness gate to make the later readback deterministic.
    await process_frame
    RenderingServer.force_sync()
    RenderingServer.call_on_render_thread(Callable(self, "_render_thread_readback"))
    started = Time.get_ticks_msec()
    while not _readback_done and Time.get_ticks_msec() - started < TIMEOUT_MS:
        await process_frame
    if not _readback_done:
        await _finish_failure("render-thread readback timed out")
        return

    var ok := bool(_result.get("supported", false)) \
        and int(_result.get("expected_visible", -1)) == int(_result.get("gpu_visible", -2)) \
        and int(_result.get("invalid_transform_rows", -1)) == 0
    if not ok:
        push_error("GPU_MULTIMESH_INDIRECT_TEST: " + str(_result))
    else:
        print("YARDMAN_GPU_MULTIMESH_INDIRECT_METRICS count=%d visible=%d record_us=%d" % [
            INSTANCE_COUNT, int(_result.gpu_visible), int(_result.record_us)])
    print("YARDMAN_GPU_MULTIMESH_INDIRECT_TEST %s gpu_resident_compaction=1 indirect_count=1 global_rd=1" % ("PASS" if ok else "FAIL"))
    await _cleanup_and_flush()
    quit(0 if ok else 1)

func _prepare_inputs() -> void:
    var spheres := PackedFloat32Array()
    spheres.resize(INSTANCE_COUNT * 4)
    for index in range(INSTANCE_COUNT):
        var base := index * 4
        spheres[base] = float((index * 73) % 401) - 200.0
        spheres[base + 1] = float((index * 151) % 301) - 150.0
        spheres[base + 2] = float((index * 199) % 501) - 250.0
        spheres[base + 3] = 0.5 + float(index % 9) * 0.35
    _sphere_bytes = spheres.to_byte_array()
    _plane_bytes = PackedFloat32Array([
        1.0, 0.0, 0.0, 50.0,
        -1.0, 0.0, 0.0, 50.0,
        0.0, 1.0, 0.0, 50.0,
        0.0, -1.0, 0.0, 50.0,
        0.0, 0.0, 1.0, 50.0,
        0.0, 0.0, -1.0, 50.0,
    ]).to_byte_array()
    _params_bytes = PackedInt32Array([INSTANCE_COUNT]).to_byte_array()

func _render_thread_dispatch() -> void:
    var rd := RenderingServer.get_rendering_device()
    if rd == null:
        _result = {"supported": false, "reason": "global RenderingDevice unavailable"}
        _dispatch_recorded = true
        _readback_done = true
        return

    _shader = rd.shader_create_from_spirv(_spirv)
    if not _shader.is_valid():
        _result = {"supported": false, "reason": "compute shader creation failed"}
        _dispatch_recorded = true
        _readback_done = true
        return

    _sphere_buffer = rd.storage_buffer_create(_sphere_bytes.size(), _sphere_bytes)
    _plane_buffer = rd.storage_buffer_create(_plane_bytes.size(), _plane_bytes)
    _params_buffer = rd.storage_buffer_create(_params_bytes.size(), _params_bytes)
    if not _sphere_buffer.is_valid() or not _plane_buffer.is_valid() or not _params_buffer.is_valid():
        _result = {"supported": false, "reason": "input buffer creation failed"}
        _free_global_rd_resources(rd)
        _dispatch_recorded = true
        _readback_done = true
        return

    _uniform_set = rd.uniform_set_create([
        _storage_uniform(0, _sphere_buffer),
        _storage_uniform(1, _plane_buffer),
        _storage_uniform(2, _params_buffer),
        _storage_uniform(3, _mm_buffer),
        _storage_uniform(4, _command_buffer),
    ], _shader, 0)
    _pipeline = rd.compute_pipeline_create(_shader)
    if not _uniform_set.is_valid() or not _pipeline.is_valid():
        _result = {"supported": false, "reason": "pipeline creation failed"}
        _free_global_rd_resources(rd)
        _dispatch_recorded = true
        _readback_done = true
        return

    # Preserve mesh-populated command fields; only clear instanceCount.
    var zero := PackedInt32Array([0]).to_byte_array()
    rd.buffer_update(_command_buffer, 4, 4, zero)
    var started := Time.get_ticks_usec()
    var list := rd.compute_list_begin()
    rd.compute_list_bind_compute_pipeline(list, _pipeline)
    rd.compute_list_bind_uniform_set(list, _uniform_set, 0)
    rd.compute_list_dispatch(list, ceili(float(INSTANCE_COUNT) / float(LOCAL_SIZE_X)), 1, 1)
    rd.compute_list_end()
    _record_us = Time.get_ticks_usec() - started
    _dispatch_recorded = true

func _render_thread_readback() -> void:
    var rd := RenderingServer.get_rendering_device()
    if rd == null:
        _result = {"supported": false, "reason": "global RenderingDevice unavailable during readback"}
        _readback_done = true
        return

    var command_values := rd.buffer_get_data(_command_buffer).to_int32_array()
    var gpu_visible := int(command_values[1]) if command_values.size() > 1 else -1
    var transforms := rd.buffer_get_data(_mm_buffer).to_float32_array()
    var invalid_rows := 0
    for instance_index in range(clampi(gpu_visible, 0, INSTANCE_COUNT)):
        var base := instance_index * 12
        if base + 11 >= transforms.size():
            invalid_rows += 1
            break
        if not is_equal_approx(transforms[base], 1.0) \
                or not is_equal_approx(transforms[base + 5], 1.0) \
                or not is_equal_approx(transforms[base + 10], 1.0):
            invalid_rows += 1

    _result = {
        "supported": true,
        "expected_visible": _expected_visible_count(),
        "gpu_visible": gpu_visible,
        "invalid_transform_rows": invalid_rows,
        "record_us": _record_us,
        "command_words": command_values.size(),
    }
    _free_global_rd_resources(rd)
    _readback_done = true

func _expected_visible_count() -> int:
    var spheres := _sphere_bytes.to_float32_array()
    var visible := 0
    for index in range(INSTANCE_COUNT):
        var base := index * 4
        var x := spheres[base]
        var y := spheres[base + 1]
        var z := spheres[base + 2]
        var radius := spheres[base + 3]
        if x + 50.0 >= -radius and -x + 50.0 >= -radius \
                and y + 50.0 >= -radius and -y + 50.0 >= -radius \
                and z + 50.0 >= -radius and -z + 50.0 >= -radius:
            visible += 1
    return visible

func _storage_uniform(binding: int, rid: RID) -> RDUniform:
    var uniform := RDUniform.new()
    uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    uniform.binding = binding
    uniform.add_id(rid)
    return uniform

func _free_global_rd_resources(rd: RenderingDevice) -> void:
    for rid_value in [_uniform_set, _pipeline, _sphere_buffer, _plane_buffer, _params_buffer, _shader]:
        if rid_value.is_valid():
            rd.free_rid(rid_value)
    _uniform_set = RID()
    _pipeline = RID()
    _sphere_buffer = RID()
    _plane_buffer = RID()
    _params_buffer = RID()
    _shader = RID()

func _cleanup_and_flush() -> void:
    if _multimesh.is_valid():
        RenderingServer.free_rid(_multimesh)
        _multimesh = RID()
    _mm_buffer = RID()
    _command_buffer = RID()
    _mesh = null
    # Let deferred renderer destruction retire its internal storage buffers.
    for _frame in range(3):
        await process_frame
    RenderingServer.force_sync()

func _finish_failure(message: String) -> void:
    push_error("GPU_MULTIMESH_INDIRECT_TEST: " + message)
    print("YARDMAN_GPU_MULTIMESH_INDIRECT_TEST FAIL")
    await _cleanup_and_flush()
    quit(1)
