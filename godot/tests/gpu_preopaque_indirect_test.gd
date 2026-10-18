extends SceneTree

const TimingEffect = preload("res://scripts/gpu_preopaque_indirect_effect.gd")
const Lifecycle = preload("res://scripts/gpu_indirect_multimesh_lifecycle.gd")
const VIEWPORT_SIZE := Vector2i(128, 128)
const COMMAND_INSTANCE_COUNT_OFFSET := 4
const COMMAND_WORD_BYTES := 4
const TIMEOUT_FRAMES := 120

var failures := 0
var _rt_mutex := Mutex.new()
var _rt_done := false
var _rt_ok := false
var _cleanup_result: Dictionary = {}

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("GPU_PREOPAQUE_INDIRECT_TEST: " + message)

func _run() -> void:
    var viewport := SubViewport.new()
    viewport.size = VIEWPORT_SIZE
    viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
    viewport.transparent_bg = false
    viewport.world_3d = World3D.new()
    get_root().add_child(viewport)

    var environment := Environment.new()
    environment.background_mode = Environment.BG_COLOR
    environment.background_color = Color.BLACK
    var world_environment := WorldEnvironment.new()
    world_environment.environment = environment
    viewport.add_child(world_environment)

    var camera := Camera3D.new()
    camera.position = Vector3(0.0, 0.0, 3.0)
    camera.current = true
    viewport.add_child(camera)
    camera.look_at(Vector3.ZERO, Vector3.UP)

    var material := StandardMaterial3D.new()
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    material.albedo_color = Color.WHITE

    var mesh := BoxMesh.new()
    mesh.size = Vector3(1.2, 1.2, 1.2)
    mesh.material = material

    var multimesh := RenderingServer.multimesh_create()
    RenderingServer.multimesh_allocate_data(multimesh, 1,
        RenderingServer.MULTIMESH_TRANSFORM_3D, false, false, true)
    RenderingServer.multimesh_set_mesh(multimesh, mesh.get_rid())
    RenderingServer.multimesh_instance_set_transform(multimesh, 0, Transform3D.IDENTITY)
    RenderingServer.multimesh_set_custom_aabb(multimesh,
        AABB(Vector3(-1.0, -1.0, -1.0), Vector3(2.0, 2.0, 2.0)))

    var command_buffer := RenderingServer.multimesh_get_command_buffer_rd_rid(multimesh)
    _check(command_buffer.is_valid(), "indirect command buffer is invalid")

    var render_instance := RenderingServer.instance_create()
    RenderingServer.instance_set_base(render_instance, multimesh)
    RenderingServer.instance_set_scenario(render_instance, viewport.world_3d.scenario)
    RenderingServer.instance_set_transform(render_instance, Transform3D.IDENTITY)

    var effect := TimingEffect.new()
    effect.set_multimesh(multimesh)
    var compositor := Compositor.new()
    var effects: Array[CompositorEffect] = [effect]
    compositor.compositor_effects = effects
    camera.compositor = compositor

    # Warm renderer resources while requesting one visible instance.
    effect.request_instance_count(1)
    viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
    for _frame in range(5):
        await process_frame
    viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
    RenderingServer.force_sync()

    var sequence := PackedInt32Array([0, 1, 0, 1])
    var lumas := PackedFloat32Array()
    for target_count in sequence:
        # Poison the command buffer to the opposite value. If PRE_OPAQUE is
        # applied one frame late, the raster oracle must show the poison value.
        var poison_count := 1 - target_count
        _check(await _write_instance_count(multimesh, poison_count),
            "failed to poison indirect count before timing frame")

        var serial := effect.request_instance_count(target_count)
        viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
        await process_frame
        RenderingServer.force_sync()
        await process_frame

        var state := effect.state()
        _check(int(state.get("applied_serial", -1)) >= serial,
            "PRE_OPAQUE callback did not apply the requested serial in the timing frame")
        _check(bool(state.get("last_write_ok", false)),
            "PRE_OPAQUE callback could not write the indirect command buffer")
        _check(int(state.get("applied_count", -1)) == target_count,
            "PRE_OPAQUE callback applied the wrong indirect count")

        var image := viewport.get_texture().get_image()
        var luma := _center_luma(image)
        lumas.append(luma)
        if target_count == 0:
            _check(luma < 0.08,
                "same-frame zero count was not near-black (luma=%.4f)" % luma)
        else:
            _check(luma > 0.35,
                "same-frame one count did not rasterize the mesh (luma=%.4f)" % luma)

    _check(lumas.size() == sequence.size(), "timing sequence did not produce every raster sample")
    if lumas.size() == sequence.size():
        _check(lumas[1] - lumas[0] > 0.30 and lumas[3] - lumas[2] > 0.30,
            "PRE_OPAQUE timing sequence did not produce stable zero-to-one raster deltas")

    var final_state := effect.state()
    _check(int(final_state.get("callback_count", 0)) >= sequence.size(),
        "PRE_OPAQUE compositor callback count is lower than the timing sequence")

    print("YARDMAN_GPU_PREOPAQUE_INDIRECT_METRICS callbacks=%d sequence=0,1,0,1 lumas=%s" % [
        int(final_state.get("callback_count", 0)), str(lumas)])

    camera.compositor = null
    effect.clear_multimesh()
    await process_frame
    RenderingServer.instance_set_scenario(render_instance, RID())
    RenderingServer.free_rid(render_instance)
    await _free_multimesh_and_sync(multimesh)
    if Lifecycle.requires_472_command_buffer_workaround():
        _check(bool(_cleanup_result.get("manual_command_free", false)),
            "Godot 4.7.2 command-buffer leak workaround did not execute")

    viewport.queue_free()
    await process_frame
    await process_frame

    print("YARDMAN_GPU_PREOPAQUE_INDIRECT_TEST %s preopaque=1 same_frame=1 poison_oracle=1 indirect_raster=1 cleanup=1" % (
        "PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)

func _write_instance_count(multimesh: RID, instance_count: int) -> bool:
    _rt_mutex.lock()
    _rt_done = false
    _rt_ok = false
    _rt_mutex.unlock()
    RenderingServer.call_on_render_thread(_write_instance_count_render_thread.bind(
        multimesh, instance_count))

    var frames := 0
    while not _is_rt_done() and frames < TIMEOUT_FRAMES:
        frames += 1
        await process_frame
    if not _is_rt_done():
        return false
    RenderingServer.force_sync()
    return _rt_success()

func _write_instance_count_render_thread(multimesh: RID, instance_count: int) -> void:
    var ok := false
    var rd := RenderingServer.get_rendering_device()
    if rd != null:
        var command_buffer := RenderingServer.multimesh_get_command_buffer_rd_rid(multimesh)
        if command_buffer.is_valid():
            var bytes := PackedInt32Array([instance_count]).to_byte_array()
            rd.buffer_update(command_buffer, COMMAND_INSTANCE_COUNT_OFFSET,
                COMMAND_WORD_BYTES, bytes)
            ok = true
    _rt_mutex.lock()
    _rt_ok = ok
    _rt_done = true
    _rt_mutex.unlock()

func _center_luma(image: Image) -> float:
    if image == null or image.is_empty():
        _check(false, "viewport image is empty")
        return -1.0
    var center := VIEWPORT_SIZE / 2
    var radius := 12
    var total := 0.0
    var samples := 0
    for y in range(center.y - radius, center.y + radius):
        for x in range(center.x - radius, center.x + radius):
            var pixel := image.get_pixel(x, y)
            total += (pixel.r + pixel.g + pixel.b) / 3.0
            samples += 1
    return total / float(maxi(samples, 1))

func _free_multimesh_and_sync(multimesh: RID) -> void:
    _rt_mutex.lock()
    _rt_done = false
    _rt_ok = false
    _cleanup_result = {}
    _rt_mutex.unlock()
    RenderingServer.call_on_render_thread(_free_multimesh_render_thread.bind(multimesh))

    var frames := 0
    while not _is_rt_done() and frames < TIMEOUT_FRAMES:
        frames += 1
        await process_frame
    _check(_is_rt_done(), "render-thread MultiMesh cleanup timed out")
    RenderingServer.force_sync()
    await process_frame

func _free_multimesh_render_thread(multimesh: RID) -> void:
    var result := Lifecycle.free_on_render_thread(multimesh)
    _rt_mutex.lock()
    _cleanup_result = result
    _rt_ok = bool(result.get("freed", false))
    _rt_done = true
    _rt_mutex.unlock()

func _is_rt_done() -> bool:
    _rt_mutex.lock()
    var value := _rt_done
    _rt_mutex.unlock()
    return value

func _rt_success() -> bool:
    _rt_mutex.lock()
    var value := _rt_ok
    _rt_mutex.unlock()
    return value
