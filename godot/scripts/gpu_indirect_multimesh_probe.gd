extends RefCounted
class_name YardmanGPUIndirectMultiMeshProbe

const COMPACT_SHADER = preload("res://shaders/gpu_indirect_multimesh.glsl")
const FINALIZE_SHADER = preload("res://shaders/gpu_indirect_multimesh_finalize.glsl")
const LOCAL_SIZE_X := 64
const STRIDE_FLOATS := 20 # Transform3D 12 + color 4 + custom data 4.

var _mutex := Mutex.new()
var _done := false
var _started := false
var _result: Dictionary = {}

func begin(multimesh: RID, count: int, surface_count: int) -> bool:
    _mutex.lock()
    if _started:
        _mutex.unlock()
        return false
    _started = true
    _mutex.unlock()
    RenderingServer.call_on_render_thread(_run_render.bind(
        multimesh, clampi(count, 64, 262144), clampi(surface_count, 1, 64)))
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

func _run_render(multimesh: RID, count: int, surface_count: int) -> void:
    var rd := RenderingServer.get_rendering_device()
    if rd == null:
        _finish({"supported": false, "reason": "global RenderingDevice unavailable"})
        return

    var destination_buffer := RenderingServer.multimesh_get_buffer_rd_rid(multimesh)
    var command_buffer := RenderingServer.multimesh_get_command_buffer_rd_rid(multimesh)
    if not destination_buffer.is_valid() or not command_buffer.is_valid():
        _finish({"supported": false, "reason": "MultiMesh RD buffers unavailable"})
        return

    var compact_shader := rd.shader_create_from_spirv(COMPACT_SHADER.get_spirv())
    var finalize_shader := rd.shader_create_from_spirv(FINALIZE_SHADER.get_spirv())
    if not compact_shader.is_valid() or not finalize_shader.is_valid():
        _free_owned(rd, [compact_shader, finalize_shader])
        _finish({"supported": false, "reason": "indirect compute shader creation failed"})
        return

    var sphere_values := PackedFloat32Array()
    sphere_values.resize(count * 4)
    var source_values := PackedFloat32Array()
    source_values.resize(count * STRIDE_FLOATS)
    for index in range(count):
        var sphere_base := index * 4
        var x := float((index * 73) % 401) - 200.0
        var y := float((index * 151) % 301) - 150.0
        var z := float((index * 199) % 501) - 250.0
        sphere_values[sphere_base] = x
        sphere_values[sphere_base + 1] = y
        sphere_values[sphere_base + 2] = z
        sphere_values[sphere_base + 3] = 0.5 + float(index % 9) * 0.35

        var base := index * STRIDE_FLOATS
        # Godot 3D MultiMesh Transform3D buffer layout.
        source_values[base + 0] = 1.0
        source_values[base + 1] = 0.0
        source_values[base + 2] = 0.0
        source_values[base + 3] = x
        source_values[base + 4] = 0.0
        source_values[base + 5] = 1.0
        source_values[base + 6] = 0.0
        source_values[base + 7] = y
        source_values[base + 8] = 0.0
        source_values[base + 9] = 0.0
        source_values[base + 10] = 1.0
        source_values[base + 11] = z
        # Color payload.
        source_values[base + 12] = float(index % 17) / 16.0
        source_values[base + 13] = float(index % 13) / 12.0
        source_values[base + 14] = float(index % 11) / 10.0
        source_values[base + 15] = 1.0
        # Custom payload. The first component is an exact source identity for
        # validation; production vegetation can keep its existing custom data.
        source_values[base + 16] = float(index)
        source_values[base + 17] = float(index % 7) / 6.0
        source_values[base + 18] = float(index % 5) / 4.0
        source_values[base + 19] = 1.0

    var sphere_bytes := sphere_values.to_byte_array()
    var source_bytes := source_values.to_byte_array()
    var compact_params_bytes := PackedInt32Array([count, STRIDE_FLOATS]).to_byte_array()
    var finalize_params_bytes := PackedInt32Array([surface_count]).to_byte_array()
    var zero_counter := PackedInt32Array([0]).to_byte_array()

    var sphere_buffer := rd.storage_buffer_create(sphere_bytes.size(), sphere_bytes)
    var source_buffer := rd.storage_buffer_create(source_bytes.size(), source_bytes)
    var compact_params_buffer := rd.storage_buffer_create(compact_params_bytes.size(), compact_params_bytes)
    var finalize_params_buffer := rd.storage_buffer_create(finalize_params_bytes.size(), finalize_params_bytes)
    var counter_buffer := rd.storage_buffer_create(zero_counter.size(), zero_counter)
    var owned := [sphere_buffer, source_buffer, compact_params_buffer,
        finalize_params_buffer, counter_buffer, compact_shader, finalize_shader]
    for buffer_rid in [sphere_buffer, source_buffer, compact_params_buffer,
            finalize_params_buffer, counter_buffer]:
        if not (buffer_rid as RID).is_valid():
            _free_owned(rd, owned)
            _finish({"supported": false, "reason": "probe storage buffer creation failed"})
            return

    var compact_set := rd.uniform_set_create([
        _storage_uniform(0, sphere_buffer),
        _storage_uniform(1, source_buffer),
        _storage_uniform(2, destination_buffer),
        _storage_uniform(3, counter_buffer),
        _storage_uniform(4, compact_params_buffer),
    ], compact_shader, 0)
    var finalize_set := rd.uniform_set_create([
        _storage_uniform(0, counter_buffer),
        _storage_uniform(1, command_buffer),
        _storage_uniform(2, finalize_params_buffer),
    ], finalize_shader, 0)
    var compact_pipeline := rd.compute_pipeline_create(compact_shader)
    var finalize_pipeline := rd.compute_pipeline_create(finalize_shader)
    owned.append_array([compact_set, finalize_set, compact_pipeline, finalize_pipeline])
    if not compact_set.is_valid() or not finalize_set.is_valid() \
            or not compact_pipeline.is_valid() or not finalize_pipeline.is_valid():
        _free_owned(rd, owned)
        _finish({"supported": false, "reason": "two-pass indirect compute pipeline creation failed"})
        return

    rd.buffer_update(counter_buffer, 0, zero_counter.size(), zero_counter)

    var started_us := Time.get_ticks_usec()
    var compute_list := rd.compute_list_begin()
    rd.compute_list_bind_compute_pipeline(compute_list, compact_pipeline)
    rd.compute_list_bind_uniform_set(compute_list, compact_set, 0)
    rd.compute_list_dispatch(compute_list, ceili(float(count) / float(LOCAL_SIZE_X)), 1, 1)
    # The finalizer consumes the atomic counter written by compaction.
    rd.compute_list_add_barrier(compute_list)
    rd.compute_list_bind_compute_pipeline(compute_list, finalize_pipeline)
    rd.compute_list_bind_uniform_set(compute_list, finalize_set, 0)
    rd.compute_list_dispatch(compute_list, ceili(float(surface_count) / float(LOCAL_SIZE_X)), 1, 1)
    rd.compute_list_end()

    # Validation-only readback. Production use must consume these GPU buffers
    # directly and must not synchronously read visibility results on CPU.
    var counter_values := rd.buffer_get_data(counter_buffer).to_int32_array()
    var command_values := rd.buffer_get_data(command_buffer).to_int32_array()
    var destination_values := rd.buffer_get_data(destination_buffer).to_float32_array()
    var elapsed_us := Time.get_ticks_usec() - started_us
    var visible_count := int(counter_values[0]) if not counter_values.is_empty() else -1
    var visible_records := PackedFloat32Array()
    if visible_count >= 0 and destination_values.size() >= visible_count * STRIDE_FLOATS:
        visible_records.resize(visible_count * STRIDE_FLOATS)
        for component in range(visible_records.size()):
            visible_records[component] = destination_values[component]

    _free_owned(rd, owned)
    _finish({
        "supported": true,
        "count": count,
        "visible": visible_count,
        "records": visible_records,
        "commands": command_values,
        "surface_count": surface_count,
        "stride_floats": STRIDE_FLOATS,
        "roundtrip_us": elapsed_us,
        "instance_buffer_valid": destination_buffer.is_valid(),
        "command_buffer_valid": command_buffer.is_valid(),
    })

func _storage_uniform(binding: int, rid: RID) -> RDUniform:
    var uniform := RDUniform.new()
    uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    uniform.binding = binding
    uniform.add_id(rid)
    return uniform

func _free_owned(rd: RenderingDevice, rids: Array) -> void:
    for rid_value in rids:
        if rid_value is RID and (rid_value as RID).is_valid():
            rd.free_rid(rid_value)

func _finish(value: Dictionary) -> void:
    _mutex.lock()
    _result = value
    _done = true
    _mutex.unlock()
