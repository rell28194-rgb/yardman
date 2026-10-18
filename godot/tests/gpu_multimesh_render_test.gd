extends SceneTree

# End-to-end proof that Godot's scene renderer consumes the GPU-written
# MultiMesh transform buffer and indirect instanceCount. Unlike the lower-level
# parity gate, this test judges pixels from a real RenderingServer viewport.
const SHADER_PATH := "res://shaders/gpu_multimesh_indirect.glsl"
const INSTANCE_COUNT := 8195
const LOCAL_SIZE_X := 64
const VIEW_SIZE := 256
const TIMEOUT_MS := 8000

var _sphere_bytes := PackedByteArray()
var _plane_bytes := PackedByteArray()
var _params_bytes := PackedByteArray()
var _spirv: RDShaderSPIRV

var _scenario := RID()
var _viewport := RID()
var _camera := RID()
var _instance := RID()
var _multimesh := RID()
var _mm_buffer := RID()
var _command_buffer := RID()
var _mesh: BoxMesh
var _material: StandardMaterial3D

var _shader := RID()
var _sphere_buffer := RID()
var _plane_buffer := RID()
var _params_buffer := RID()
var _uniform_set := RID()
var _pipeline := RID()

var _dispatch_recorded := false
var _zero_recorded := false
var _gpu_retired := false
var _failure := ""

func _initialize() -> void:
    call_deferred("_run")

func _run() -> void:
    _prepare_inputs()
    var shader_file := load(SHADER_PATH) as RDShaderFile
    if shader_file == null:
        await _fail("shader resource unavailable")
        return
    _spirv = shader_file.get_spirv()
    _create_render_scene()
    if not _failure.is_empty():
        await _fail(_failure)
        return

    RenderingServer.call_on_render_thread(Callable(self, "_render_thread_dispatch"))
    if not await _wait_flag("dispatch"):
        await _fail("render-thread compute dispatch timed out")
        return
    if not _failure.is_empty():
        await _fail(_failure)
        return

    # Give the renderer a full frame after compute submission, then capture a
    # synchronized viewport image. Synchronization is test-only and is never a
    # proposed production-frame operation.
    await process_frame
    RenderingServer.force_draw(false, 0.0)
    RenderingServer.force_sync()
    var visible_image := _viewport_image()
    if visible_image == null:
        await _fail("could not capture populated indirect viewport")
        return
    var visible_pixels := _covered_pixels(visible_image)

    # Mutate only the indirect instanceCount on the GPU command buffer. If the
    # viewport actually consumes that command, the same MultiMesh must vanish
    # without changing scene nodes, mesh data, or CPU-visible instance lists.
    RenderingServer.call_on_render_thread(Callable(self, "_render_thread_zero_count"))
    if not await _wait_flag("zero"):
        await _fail("render-thread zero-count update timed out")
        return
    await process_frame
    RenderingServer.force_draw(false, 0.0)
    RenderingServer.force_sync()
    var zero_image := _viewport_image()
    if zero_image == null:
        await _fail("could not capture zero-count indirect viewport")
        return
    var zero_pixels := _covered_pixels(zero_image)

    var pixel_delta := visible_pixels - zero_pixels
    var ok := visible_pixels >= 64 and zero_pixels <= 4 and pixel_delta >= 60
    if not ok:
        push_error("GPU_MULTIMESH_RENDER_TEST: populated=%d zero=%d delta=%d" % [
            visible_pixels, zero_pixels, pixel_delta])
    else:
        print("YARDMAN_GPU_MULTIMESH_RENDER_METRICS populated_pixels=%d zero_pixels=%d delta=%d" % [
            visible_pixels, zero_pixels, pixel_delta])
    print("YARDMAN_GPU_MULTIMESH_RENDER_TEST %s actual_pixels=1 indirect_zero=1" % ("PASS" if ok else "FAIL"))

    await _cleanup()
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

func _create_render_scene() -> void:
    _material = StandardMaterial3D.new()
    _material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    _material.albedo_color = Color.WHITE
    _mesh = BoxMesh.new()
    _mesh.size = Vector3(2.0, 2.0, 2.0)
    _mesh.material = _material

    _multimesh = RenderingServer.multimesh_create()
    RenderingServer.multimesh_allocate_data(
        _multimesh, INSTANCE_COUNT, RenderingServer.MULTIMESH_TRANSFORM_3D,
        false, false, true)
    RenderingServer.multimesh_set_mesh(_multimesh, _mesh.get_rid())

    _scenario = RenderingServer.scenario_create()
    _viewport = RenderingServer.viewport_create()
    _camera = RenderingServer.camera_create()
    _instance = RenderingServer.instance_create()
    RenderingServer.viewport_set_size(_viewport, VIEW_SIZE, VIEW_SIZE)
    RenderingServer.viewport_set_update_mode(_viewport, RenderingServer.VIEWPORT_UPDATE_ALWAYS)
    RenderingServer.viewport_set_transparent_background(_viewport, true)
    RenderingServer.viewport_set_scenario(_viewport, _scenario)
    RenderingServer.viewport_attach_camera(_viewport, _camera)
    RenderingServer.viewport_set_active(_viewport, true)
    RenderingServer.camera_set_orthogonal(_camera, 120.0, 0.1, 300.0)
    RenderingServer.camera_set_transform(_camera, Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 150.0)))
    RenderingServer.instance_set_base(_instance, _multimesh)
    RenderingServer.instance_set_scenario(_instance, _scenario)
    # CPU-side MultiMesh AABB generation cannot know GPU-written transforms.
    # The production design therefore requires a conservative cluster AABB.
    RenderingServer.instance_set_custom_aabb(
        _instance, AABB(Vector3(-60.0, -60.0, -60.0), Vector3(120.0, 120.0, 120.0)))

    # Realize mesh/multimesh buffers before the render-thread callback reads RIDs.
    RenderingServer.force_draw(false, 0.0)
    RenderingServer.force_sync()
    _mm_buffer = RenderingServer.multimesh_get_buffer_rd_rid(_multimesh)
    _command_buffer = RenderingServer.multimesh_get_command_buffer_rd_rid(_multimesh)
    if not _mm_buffer.is_valid() or not _command_buffer.is_valid():
        _failure = "RenderingServer did not expose indirect MultiMesh GPU buffers"

func _render_thread_dispatch() -> void:
    var rd := RenderingServer.get_rendering_device()
    if rd == null:
        _failure = "global RenderingDevice unavailable"
        _dispatch_recorded = true
        return
    _shader = rd.shader_create_from_spirv(_spirv)
    if not _shader.is_valid():
        _failure = "compute shader creation failed"
        _dispatch_recorded = true
        return
    _sphere_buffer = rd.storage_buffer_create(_sphere_bytes.size(), _sphere_bytes)
    _plane_buffer = rd.storage_buffer_create(_plane_bytes.size(), _plane_bytes)
    _params_buffer = rd.storage_buffer_create(_params_bytes.size(), _params_bytes)
    if not _sphere_buffer.is_valid() or not _plane_buffer.is_valid() or not _params_buffer.is_valid():
        _failure = "input storage buffer creation failed"
        _dispatch_recorded = true
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
        _failure = "compute pipeline creation failed"
        _dispatch_recorded = true
        return

    var zero := PackedInt32Array([0]).to_byte_array()
    rd.buffer_update(_command_buffer, 4, 4, zero)
    var list := rd.compute_list_begin()
    rd.compute_list_bind_compute_pipeline(list, _pipeline)
    rd.compute_list_bind_uniform_set(list, _uniform_set, 0)
    rd.compute_list_dispatch(list, ceili(float(INSTANCE_COUNT) / float(LOCAL_SIZE_X)), 1, 1)
    rd.compute_list_end()
    _dispatch_recorded = true

func _render_thread_zero_count() -> void:
    var rd := RenderingServer.get_rendering_device()
    if rd == null or not _command_buffer.is_valid():
        _failure = "global RenderingDevice/command buffer unavailable for zero-count update"
        _zero_recorded = true
        return
    var zero := PackedInt32Array([0]).to_byte_array()
    rd.buffer_update(_command_buffer, 4, 4, zero)
    _zero_recorded = true

func _render_thread_retire() -> void:
    var rd := RenderingServer.get_rendering_device()
    if rd == null:
        _failure = "global RenderingDevice unavailable during cleanup"
        _gpu_retired = true
        return
    # Uniforms and pipeline are retired first while all referenced buffers are
    # still valid. Godot 4.7.2 does not free the old indirect command SSBO when
    # its RD MultiMesh is reallocated/freed, so Yardman explicitly retires the
    # exposed command RID after descriptor teardown.
    for rid_value in [_uniform_set, _pipeline, _sphere_buffer, _plane_buffer, _params_buffer, _shader]:
        if rid_value.is_valid():
            rd.free_rid(rid_value)
    _uniform_set = RID()
    _pipeline = RID()
    _sphere_buffer = RID()
    _plane_buffer = RID()
    _params_buffer = RID()
    _shader = RID()
    if _command_buffer.is_valid():
        rd.free_rid(_command_buffer)
        _command_buffer = RID()
    _gpu_retired = true

func _viewport_image() -> Image:
    var texture_rid := RenderingServer.viewport_get_texture(_viewport)
    if not texture_rid.is_valid():
        return null
    return RenderingServer.texture_2d_get(texture_rid)

func _covered_pixels(image: Image) -> int:
    var count := 0
    # Sample every second pixel: enough to prove rendered coverage while keeping
    # this CI gate cheap under software Vulkan.
    for y in range(0, image.get_height(), 2):
        for x in range(0, image.get_width(), 2):
            var pixel := image.get_pixel(x, y)
            if pixel.a > 0.20 and (pixel.r + pixel.g + pixel.b) > 0.35:
                count += 1
    return count

func _storage_uniform(binding: int, rid: RID) -> RDUniform:
    var uniform := RDUniform.new()
    uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    uniform.binding = binding
    uniform.add_id(rid)
    return uniform

func _wait_flag(which: String) -> bool:
    var started := Time.get_ticks_msec()
    while Time.get_ticks_msec() - started < TIMEOUT_MS:
        if (which == "dispatch" and _dispatch_recorded) \
                or (which == "zero" and _zero_recorded) \
                or (which == "retire" and _gpu_retired):
            return true
        await process_frame
    return false

func _cleanup() -> void:
    if _viewport.is_valid():
        RenderingServer.viewport_set_active(_viewport, false)
    if _instance.is_valid():
        RenderingServer.free_rid(_instance)
        _instance = RID()
    RenderingServer.force_draw(false, 0.0)
    RenderingServer.force_sync()

    RenderingServer.call_on_render_thread(Callable(self, "_render_thread_retire"))
    await _wait_flag("retire")

    if _multimesh.is_valid():
        _mm_buffer = RID()
        RenderingServer.multimesh_allocate_data(
            _multimesh, 0, RenderingServer.MULTIMESH_TRANSFORM_3D,
            false, false, false)
        RenderingServer.free_rid(_multimesh)
        _multimesh = RID()
    for rid_value in [_camera, _viewport, _scenario]:
        if rid_value.is_valid():
            RenderingServer.free_rid(rid_value)
    _camera = RID()
    _viewport = RID()
    _scenario = RID()
    _mesh = null
    _material = null
    for _frame in range(3):
        RenderingServer.force_draw(false, 0.0)
        await process_frame
    RenderingServer.force_sync()

func _fail(message: String) -> void:
    push_error("GPU_MULTIMESH_RENDER_TEST: " + message)
    print("YARDMAN_GPU_MULTIMESH_RENDER_TEST FAIL")
    await _cleanup()
    quit(1)
