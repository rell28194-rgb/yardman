extends RefCounted
class_name YardmanGPUVisibilityProbe

const SHADER_PATH := "res://shaders/gpu_visibility.glsl"
const LOCAL_SIZE_X := 64

static func run_probe(count: int = 4096) -> Dictionary:
    count = clampi(count, 64, 262144)
    var rd := RenderingServer.create_local_rendering_device()
    if rd == null:
        return {"supported": false, "reason": "local RenderingDevice unavailable"}

    var shader_file := load(SHADER_PATH) as RDShaderFile
    if shader_file == null:
        return _fail(rd, [], "compute shader resource unavailable")
    var shader_rid := rd.shader_create_from_spirv(shader_file.get_spirv())
    if not shader_rid.is_valid():
        return _fail(rd, [], "compute shader creation failed")

    var sphere_values := PackedFloat32Array()
    sphere_values.resize(count * 4)
    for index in range(count):
        var base := index * 4
        sphere_values[base] = float((index * 73) % 401) - 200.0
        sphere_values[base + 1] = float((index * 151) % 301) - 150.0
        sphere_values[base + 2] = float((index * 199) % 501) - 250.0
        sphere_values[base + 3] = 0.5 + float(index % 9) * 0.35

    # Six inward-facing planes enclosing an axis-aligned 100 m test volume.
    var plane_values := PackedFloat32Array([
        1.0, 0.0, 0.0, 50.0,
        -1.0, 0.0, 0.0, 50.0,
        0.0, 1.0, 0.0, 50.0,
        0.0, -1.0, 0.0, 50.0,
        0.0, 0.0, 1.0, 50.0,
        0.0, 0.0, -1.0, 50.0,
    ])
    var output_values := PackedInt32Array()
    output_values.resize(count)
    var visible_index_values := PackedInt32Array()
    visible_index_values.resize(count)
    var params_values := PackedInt32Array([count])
    var zero_counter := PackedInt32Array([0]).to_byte_array()

    var sphere_bytes := sphere_values.to_byte_array()
    var plane_bytes := plane_values.to_byte_array()
    var output_bytes := output_values.to_byte_array()
    var visible_index_bytes := visible_index_values.to_byte_array()
    var params_bytes := params_values.to_byte_array()
    var sphere_buffer := rd.storage_buffer_create(sphere_bytes.size(), sphere_bytes)
    var plane_buffer := rd.storage_buffer_create(plane_bytes.size(), plane_bytes)
    var visibility_buffer := rd.storage_buffer_create(output_bytes.size(), output_bytes)
    var params_buffer := rd.storage_buffer_create(params_bytes.size(), params_bytes)
    var visible_index_buffer := rd.storage_buffer_create(visible_index_bytes.size(), visible_index_bytes)
    var counter_buffer := rd.storage_buffer_create(zero_counter.size(), zero_counter)
    var buffers := [sphere_buffer, plane_buffer, visibility_buffer, params_buffer,
        visible_index_buffer, counter_buffer]
    for buffer_rid in buffers:
        if not (buffer_rid as RID).is_valid():
            buffers.append(shader_rid)
            return _fail(rd, buffers, "storage buffer creation failed")

    var sphere_uniform := _storage_uniform(0, sphere_buffer)
    var plane_uniform := _storage_uniform(1, plane_buffer)
    var visibility_uniform := _storage_uniform(2, visibility_buffer)
    var params_uniform := _storage_uniform(3, params_buffer)
    var visible_index_uniform := _storage_uniform(4, visible_index_buffer)
    var counter_uniform := _storage_uniform(5, counter_buffer)

    var uniform_set := rd.uniform_set_create([
        sphere_uniform, plane_uniform, visibility_uniform, params_uniform,
        visible_index_uniform, counter_uniform], shader_rid, 0)
    var pipeline := rd.compute_pipeline_create(shader_rid)
    if not uniform_set.is_valid() or not pipeline.is_valid():
        return _fail(rd, [uniform_set, pipeline, sphere_buffer, plane_buffer,
            visibility_buffer, params_buffer, visible_index_buffer, counter_buffer,
            shader_rid], "compute pipeline creation failed")

    # Warm once so the measured dispatch does not include first-use pipeline work.
    _dispatch(rd, pipeline, uniform_set, count)
    rd.sync()
    rd.buffer_update(counter_buffer, 0, zero_counter.size(), zero_counter)
    var gpu_started := Time.get_ticks_usec()
    _dispatch(rd, pipeline, uniform_set, count)
    rd.sync()
    var gpu_us := Time.get_ticks_usec() - gpu_started

    var gpu_values := rd.buffer_get_data(visibility_buffer).to_int32_array()
    var gpu_counter_values := rd.buffer_get_data(counter_buffer).to_int32_array()
    var gpu_visible_count := int(gpu_counter_values[0]) if not gpu_counter_values.is_empty() else -1
    var gpu_compacted := rd.buffer_get_data(visible_index_buffer).to_int32_array()
    gpu_compacted.resize(clampi(gpu_visible_count, 0, count))
    gpu_compacted.sort()

    var cpu_started := Time.get_ticks_usec()
    var mismatches := 0
    var expected_compacted := PackedInt32Array()
    for index in range(count):
        var base := index * 4
        var center := Vector3(sphere_values[base], sphere_values[base + 1], sphere_values[base + 2])
        var radius := sphere_values[base + 3]
        var cpu_visible := _cpu_visible(center, radius)
        var gpu_visible := index < gpu_values.size() and gpu_values[index] != 0
        if cpu_visible:
            expected_compacted.append(index)
        if cpu_visible != gpu_visible:
            mismatches += 1
    var cpu_us := Time.get_ticks_usec() - cpu_started

    var compact_mismatches := absi(expected_compacted.size() - gpu_compacted.size())
    var comparable := mini(expected_compacted.size(), gpu_compacted.size())
    for index in range(comparable):
        if expected_compacted[index] != gpu_compacted[index]:
            compact_mismatches += 1

    var result := {
        "supported": true,
        "count": count,
        "visible": expected_compacted.size(),
        "gpu_visible_count": gpu_visible_count,
        "mismatches": mismatches,
        "compact_mismatches": compact_mismatches,
        "gpu_dispatch_us": gpu_us,
        "cpu_reference_us": cpu_us,
    }
    _free_rids(rd, [uniform_set, pipeline, sphere_buffer, plane_buffer,
        visibility_buffer, params_buffer, visible_index_buffer, counter_buffer, shader_rid])
    rd.free()
    return result

static func _storage_uniform(binding: int, rid: RID) -> RDUniform:
    var uniform := RDUniform.new()
    uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    uniform.binding = binding
    uniform.add_id(rid)
    return uniform

static func _dispatch(rd: RenderingDevice, pipeline: RID, uniform_set: RID, count: int) -> void:
    var compute_list := rd.compute_list_begin()
    rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
    rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
    rd.compute_list_dispatch(compute_list, ceili(float(count) / float(LOCAL_SIZE_X)), 1, 1)
    rd.compute_list_end()
    rd.submit()

static func _cpu_visible(center: Vector3, radius: float) -> bool:
    return center.x + 50.0 >= -radius and -center.x + 50.0 >= -radius \
        and center.y + 50.0 >= -radius and -center.y + 50.0 >= -radius \
        and center.z + 50.0 >= -radius and -center.z + 50.0 >= -radius

static func _fail(rd: RenderingDevice, rids: Array, reason: String) -> Dictionary:
    _free_rids(rd, rids)
    rd.free()
    return {"supported": false, "reason": reason}

static func _free_rids(rd: RenderingDevice, rids: Array) -> void:
    for rid_value in rids:
        if rid_value is RID and (rid_value as RID).is_valid():
            rd.free_rid(rid_value)
