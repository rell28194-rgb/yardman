extends CompositorEffect
class_name YardmanDepthCaptureEffect

const DEPTH_CAPTURE_SHADER = preload("res://shaders/gpu_depth_capture.glsl")
const LOCAL_SIZE_X := 8
const LOCAL_SIZE_Y := 8
const FLOATS_PER_PIXEL := 2

var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _nearest_sampler := RID()
var _output_buffer := RID()
var _output_size := Vector2i.ZERO
var _buffer_reallocations := 0
var _frames_captured := 0

var _mutex := Mutex.new()
var _snapshot_requested := false
var _snapshot_ready := false
var _snapshot: Dictionary = {}
var _release_done := false

func _init() -> void:
    effect_callback_type = EFFECT_CALLBACK_TYPE_POST_OPAQUE
    access_resolved_depth = true
    _rd = RenderingServer.get_rendering_device()

func request_snapshot() -> void:
    _mutex.lock()
    _snapshot_requested = true
    _snapshot_ready = false
    _mutex.unlock()

func snapshot_ready() -> bool:
    _mutex.lock()
    var ready := _snapshot_ready
    _mutex.unlock()
    return ready

func take_snapshot() -> Dictionary:
    _mutex.lock()
    var value := _snapshot.duplicate(true)
    _snapshot_ready = false
    _mutex.unlock()
    return value

func release_resources() -> void:
    _mutex.lock()
    _release_done = false
    _mutex.unlock()
    RenderingServer.call_on_render_thread(_release_render_resources)

func release_done() -> bool:
    _mutex.lock()
    var done := _release_done
    _mutex.unlock()
    return done

func _render_callback(callback_type: EffectCallbackType, render_data: RenderData) -> void:
    if _rd == null or callback_type != EFFECT_CALLBACK_TYPE_POST_OPAQUE:
        return
    if not _ensure_pipeline():
        return
    var render_buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
    var scene_data := render_data.get_render_scene_data()
    if render_buffers == null or scene_data == null:
        return
    var size := render_buffers.get_internal_size()
    if size.x <= 0 or size.y <= 0:
        return
    if not _ensure_output_buffer(size):
        return

    var depth_image := render_buffers.get_depth_layer(0)
    if not depth_image.is_valid():
        return
    var inverse_projection: Projection = scene_data.get_cam_projection().inverse()
    var push_values := _encode_push_constants(inverse_projection, size)
    if push_values.size() != 20:
        return

    var depth_uniform := RDUniform.new()
    depth_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
    depth_uniform.binding = 0
    depth_uniform.add_id(_nearest_sampler)
    depth_uniform.add_id(depth_image)
    var output_uniform := RDUniform.new()
    output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    output_uniform.binding = 1
    output_uniform.add_id(_output_buffer)
    var uniform_set := UniformSetCacheRD.get_cache(_shader, 0, [depth_uniform, output_uniform])
    if not uniform_set.is_valid():
        return

    var compute_list := _rd.compute_list_begin()
    _rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)
    _rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
    var push_bytes := push_values.to_byte_array()
    _rd.compute_list_set_push_constant(compute_list, push_bytes, push_bytes.size())
    _rd.compute_list_dispatch(compute_list,
        ceili(float(size.x) / float(LOCAL_SIZE_X)),
        ceili(float(size.y) / float(LOCAL_SIZE_Y)), 1)
    _rd.compute_list_end()
    _frames_captured += 1

    var should_snapshot := false
    _mutex.lock()
    if _snapshot_requested:
        _snapshot_requested = false
        should_snapshot = true
    _mutex.unlock()
    if should_snapshot:
        var values := _rd.buffer_get_data(_output_buffer).to_float32_array()
        _mutex.lock()
        _snapshot = {
            "size": size,
            "values": values,
            "frames_captured": _frames_captured,
            "buffer_reallocations": _buffer_reallocations,
            "z_near": scene_data.get_cam_projection().get_z_near(),
            "z_far": scene_data.get_cam_projection().get_z_far(),
        }
        _snapshot_ready = true
        _mutex.unlock()

func _ensure_pipeline() -> bool:
    if _pipeline.is_valid():
        return true
    var spirv := DEPTH_CAPTURE_SHADER.get_spirv()
    _shader = _rd.shader_create_from_spirv(spirv)
    if not _shader.is_valid():
        return false
    _pipeline = _rd.compute_pipeline_create(_shader)
    if not _pipeline.is_valid():
        _rd.free_rid(_shader)
        _shader = RID()
        return false
    var sampler_state := RDSamplerState.new()
    sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
    sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
    sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
    sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
    sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
    _nearest_sampler = _rd.sampler_create(sampler_state)
    if not _nearest_sampler.is_valid():
        _rd.free_rid(_shader)
        _shader = RID()
        _pipeline = RID()
        return false
    return true

func _ensure_output_buffer(size: Vector2i) -> bool:
    if _output_buffer.is_valid() and _output_size == size:
        return true
    if _output_buffer.is_valid():
        _rd.free_rid(_output_buffer)
        _output_buffer = RID()
    var zeros := PackedFloat32Array()
    zeros.resize(size.x * size.y * FLOATS_PER_PIXEL)
    _output_buffer = _rd.storage_buffer_create(zeros.to_byte_array().size(), zeros.to_byte_array())
    if not _output_buffer.is_valid():
        _output_size = Vector2i.ZERO
        return false
    _output_size = size
    _buffer_reallocations += 1
    return true

static func _encode_push_constants(inverse_projection: Projection, size: Vector2i) -> PackedFloat32Array:
    var values := PackedFloat32Array()
    for column: Vector4 in [inverse_projection.x, inverse_projection.y, inverse_projection.z, inverse_projection.w]:
        values.append(column.x)
        values.append(column.y)
        values.append(column.z)
        values.append(column.w)
    values.append(float(size.x))
    values.append(float(size.y))
    values.append(0.0)
    values.append(0.0)
    return values

func _release_render_resources() -> void:
    if _rd != null:
        if _output_buffer.is_valid():
            _rd.free_rid(_output_buffer)
        if _nearest_sampler.is_valid():
            _rd.free_rid(_nearest_sampler)
        if _shader.is_valid():
            _rd.free_rid(_shader)
    _output_buffer = RID()
    _nearest_sampler = RID()
    _pipeline = RID()
    _shader = RID()
    _output_size = Vector2i.ZERO
    _mutex.lock()
    _release_done = true
    _mutex.unlock()
