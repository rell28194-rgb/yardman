extends RefCounted
class_name YardmanGPURoadsideSharedProbe

const COMPACT_SHADER = preload("res://shaders/gpu_roadside_shared.glsl")
const FINALIZE_SHADER = preload("res://shaders/gpu_roadside_shared_finalize.glsl")
const LOCAL_SIZE_X := 64
const SOURCE_STRIDE_FLOATS := 8
const DESTINATION_STRIDE_FLOATS := 20
const NEAR_END := 28.0
const FAR_BEGIN := 28.0
const FAR_END := 60.0
const GRASS_END := 16.0

var _mutex := Mutex.new()
var _started := false
var _done := false
var _result: Dictionary = {}

func begin(near_multimesh: RID, far_multimesh: RID, grass_multimesh: RID,
        count: int, surface_count: int) -> bool:
    _mutex.lock()
    if _started:
        _mutex.unlock()
        return false
    _started = true
    _mutex.unlock()
    RenderingServer.call_on_render_thread(_run_render.bind(
        near_multimesh, far_multimesh, grass_multimesh,
        clampi(count, 64, 262144), clampi(surface_count, 1, 64)))
    return true

func is_done() -> bool:
    _mutex.lock()
    var value := _done
    _mutex.unlock()
    return value

func result() -> Dictionary:
    _mutex.lock()
    var value := _result.duplicate(true)
    _mutex.unlock()
    return value

func _run_render(near_multimesh: RID, far_multimesh: RID, grass_multimesh: RID,
        count: int, surface_count: int) -> void:
    var rd := RenderingServer.get_rendering_device()
    if rd == null:
        _finish({"supported": false, "reason": "global RenderingDevice unavailable"})
        return

    var near_buffer := RenderingServer.multimesh_get_buffer_rd_rid(near_multimesh)
    var far_buffer := RenderingServer.multimesh_get_buffer_rd_rid(far_multimesh)
    var grass_buffer := RenderingServer.multimesh_get_buffer_rd_rid(grass_multimesh)
    var near_commands := RenderingServer.multimesh_get_command_buffer_rd_rid(near_multimesh)
    var far_commands := RenderingServer.multimesh_get_command_buffer_rd_rid(far_multimesh)
    var grass_commands := RenderingServer.multimesh_get_command_buffer_rd_rid(grass_multimesh)
    for rid_value in [near_buffer, far_buffer, grass_buffer, near_commands, far_commands, grass_commands]:
        if not (rid_value as RID).is_valid():
            _finish({"supported": false, "reason": "one or more roadside MultiMesh RD buffers unavailable"})
            return

    var compact_shader := rd.shader_create_from_spirv(COMPACT_SHADER.get_spirv())
    var finalize_shader := rd.shader_create_from_spirv(FINALIZE_SHADER.get_spirv())
    if not compact_shader.is_valid() or not finalize_shader.is_valid():
        _free_owned(rd, [compact_shader, finalize_shader])
        _finish({"supported": false, "reason": "packed roadside shader creation failed"})
        return

    var source_values := PackedFloat32Array()
    source_values.resize(count * SOURCE_STRIDE_FLOATS)
    for index in range(count):
        var source := source_record(index, count)
        var base := index * SOURCE_STRIDE_FLOATS
        for component in range(SOURCE_STRIDE_FLOATS):
            source_values[base + component] = source[component]

    var source_bytes := source_values.to_byte_array()
    var zero_counts := PackedInt32Array([0, 0, 0, 0]).to_byte_array()
    var count_params := PackedInt32Array([count, 0, 0, 0]).to_byte_array()
    var range_params := PackedFloat32Array([NEAR_END, FAR_BEGIN, FAR_END, GRASS_END]).to_byte_array()
    var surface_params := PackedInt32Array([surface_count, surface_count, surface_count, 0]).to_byte_array()

    var source_buffer := rd.storage_buffer_create(source_bytes.size(), source_bytes)
    var counter_buffer := rd.storage_buffer_create(zero_counts.size(), zero_counts)
    var count_buffer := rd.storage_buffer_create(count_params.size(), count_params)
    var range_buffer := rd.storage_buffer_create(range_params.size(), range_params)
    var surface_buffer := rd.storage_buffer_create(surface_params.size(), surface_params)
    var owned := [source_buffer, counter_buffer, count_buffer, range_buffer, surface_buffer,
        compact_shader, finalize_shader]
    for rid_value in [source_buffer, counter_buffer, count_buffer, range_buffer, surface_buffer]:
        if not (rid_value as RID).is_valid():
            _free_owned(rd, owned)
            _finish({"supported": false, "reason": "packed roadside storage buffer creation failed"})
            return

    var compact_set := rd.uniform_set_create([
        _storage_uniform(0, source_buffer),
        _storage_uniform(1, near_buffer),
        _storage_uniform(2, far_buffer),
        _storage_uniform(3, grass_buffer),
        _storage_uniform(4, counter_buffer),
        _storage_uniform(5, count_buffer),
        _storage_uniform(6, range_buffer),
    ], compact_shader, 0)
    var finalize_set := rd.uniform_set_create([
        _storage_uniform(0, counter_buffer),
        _storage_uniform(1, near_commands),
        _storage_uniform(2, far_commands),
        _storage_uniform(3, grass_commands),
        _storage_uniform(4, surface_buffer),
    ], finalize_shader, 0)
    var compact_pipeline := rd.compute_pipeline_create(compact_shader)
    var finalize_pipeline := rd.compute_pipeline_create(finalize_shader)
    owned.append_array([compact_set, finalize_set, compact_pipeline, finalize_pipeline])
    if not compact_set.is_valid() or not finalize_set.is_valid() \
            or not compact_pipeline.is_valid() or not finalize_pipeline.is_valid():
        _free_owned(rd, owned)
        _finish({"supported": false, "reason": "packed roadside pipeline creation failed"})
        return

    rd.buffer_update(counter_buffer, 0, zero_counts.size(), zero_counts)
    var started_us := Time.get_ticks_usec()
    var compute_list := rd.compute_list_begin()
    rd.compute_list_bind_compute_pipeline(compute_list, compact_pipeline)
    rd.compute_list_bind_uniform_set(compute_list, compact_set, 0)
    rd.compute_list_dispatch(compute_list, ceili(float(count) / float(LOCAL_SIZE_X)), 1, 1)
    rd.compute_list_add_barrier(compute_list)
    rd.compute_list_bind_compute_pipeline(compute_list, finalize_pipeline)
    rd.compute_list_bind_uniform_set(compute_list, finalize_set, 0)
    rd.compute_list_dispatch(compute_list, ceili(float(surface_count) / float(LOCAL_SIZE_X)), 1, 1)
    rd.compute_list_end()

    # Validation-only readback. Production keeps counts and records on GPU.
    var counts := rd.buffer_get_data(counter_buffer).to_int32_array()
    var near_values := rd.buffer_get_data(near_buffer).to_float32_array()
    var far_values := rd.buffer_get_data(far_buffer).to_float32_array()
    var grass_values := rd.buffer_get_data(grass_buffer).to_float32_array()
    var near_command_values := rd.buffer_get_data(near_commands).to_int32_array()
    var far_command_values := rd.buffer_get_data(far_commands).to_int32_array()
    var grass_command_values := rd.buffer_get_data(grass_commands).to_int32_array()
    var elapsed_us := Time.get_ticks_usec() - started_us
    var near_count := int(counts[0]) if counts.size() > 0 else -1
    var far_count := int(counts[1]) if counts.size() > 1 else -1
    var grass_count := int(counts[2]) if counts.size() > 2 else -1

    var near_visible := _prefix(near_values, near_count * DESTINATION_STRIDE_FLOATS)
    var far_visible := _prefix(far_values, far_count * DESTINATION_STRIDE_FLOATS)
    var grass_visible := _prefix(grass_values, grass_count * DESTINATION_STRIDE_FLOATS)
    _free_owned(rd, owned)
    _finish({
        "supported": true,
        "count": count,
        "source_bytes": source_bytes.size(),
        "source_stride_floats": SOURCE_STRIDE_FLOATS,
        "destination_stride_floats": DESTINATION_STRIDE_FLOATS,
        "near_count": near_count,
        "far_count": far_count,
        "grass_count": grass_count,
        "near_records": near_visible,
        "far_records": far_visible,
        "grass_records": grass_visible,
        "near_commands": near_command_values,
        "far_commands": far_command_values,
        "grass_commands": grass_command_values,
        "surface_count": surface_count,
        "roundtrip_us": elapsed_us,
    })

static func source_record(index: int, count: int) -> PackedFloat32Array:
    var x := float((index * 73) % 97) - 48.0
    var y := float((index * 31) % 17) - 8.0
    var z := float((index * 53) % 97) - 48.0
    var yaw := float((index * 127) % 6283) / 1000.0
    var scale := 0.62 + float(index % 29) / 50.0
    var identity := float(index) / float(maxi(count - 1, 1))
    var custom_y := float(index % 421) / 421.0
    var dryness := 0.10 + float(index % 51) / 100.0
    return PackedFloat32Array([x, y, z, yaw, scale, identity, custom_y, dryness])

func _prefix(values: PackedFloat32Array, requested: int) -> PackedFloat32Array:
    var size := clampi(requested, 0, values.size())
    var result := PackedFloat32Array()
    result.resize(size)
    for index in range(size):
        result[index] = values[index]
    return result

func _storage_uniform(binding: int, rid: RID) -> RDUniform:
    var uniform := RDUniform.new()
    uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    uniform.binding = binding
    uniform.add_id(rid)
    return uniform

func _free_owned(rd: RenderingDevice, rids: Array) -> void:
    for index in range(rids.size() - 1, -1, -1):
        var rid_value = rids[index]
        if rid_value is RID and (rid_value as RID).is_valid():
            rd.free_rid(rid_value)

func _finish(value: Dictionary) -> void:
    _mutex.lock()
    _result = value
    _done = true
    _mutex.unlock()
