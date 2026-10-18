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
        return {"supported": false, "reason": "compute shader resource unavailable"}
    var shader_rid := rd.shader_create_from_spirv(shader_file.get_spirv())
    if not shader_rid.is_valid():
        return {"supported": false, "reason": "compute shader creation failed"}

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

    var sphere_buffer := rd.storage_buffer_create(sphere_values.to_byte_array().size(), sphere_values.to_byte_array())
    var plane_buffer := rd.storage_buffer_create(plane_values.to_byte_array().size(), plane_values.to_byte_array())
    var visibility_buffer := rd.storage_buffer_create(output_values.to_byte_array().size(), output_values.to_byte_array())
    if not sphere_buffer.is_valid() or not plane_buffer.is_valid() or not visibility_buffer.is_valid():
        _free_rids(rd, [sphere_buffer, plane_buffer, visibility_buffer, shader_rid])
        return {"supported": false, "reason": "storage buffer creation failed"}

    var sphere_uniform := RDUniform.new()
    sphere_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    sphere_uniform.binding = 0
    sphere_uniform.add_id(sphere_buffer)
    var plane_uniform := RDUniform.new()
    plane_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    plane_uniform.binding = 1
    plane_uniform.add_id(plane_buffer)
    var visibility_uniform := RDUniform.new()
    visibility_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    visibility_uniform.binding = 2
    visibility_uniform.add_id(visibility_buffer)

    var uniform_set := rd.uniform_set_create([sphere_uniform, plane_uniform, visibility_uniform], shader_rid, 0)
    var pipeline := rd.compute_pipeline_create(shader_rid)
    if not uniform_set.is_valid() or not pipeline.is_valid():
        _free_rids(rd, [uniform_set, pipeline, sphere_buffer, plane_buffer, visibility_buffer, shader_rid])
        return {"supported": false, "reason": "compute pipeline creation failed"}

    # Warm once so the measured dispatch does not include first-use pipeline work.
    _dispatch(rd, pipeline, uniform_set, count)
    rd.sync()
    var gpu_started := Time.get_ticks_usec()
    _dispatch(rd, pipeline, uniform_set, count)
    rd.sync()
    var gpu_us := Time.get_ticks_usec() - gpu_started

    var gpu_values := rd.buffer_get_data(visibility_buffer).to_int32_array()
    var cpu_started := Time.get_ticks_usec()
    var mismatches := 0
    var visible_count := 0
    for index in range(count):
        var base := index * 4
        var center := Vector3(sphere_values[base], sphere_values[base + 1], sphere_values[base + 2])
        var radius := sphere_values[base + 3]
        var cpu_visible := _cpu_visible(center, radius)
        var gpu_visible := index < gpu_values.size() and gpu_values[index] != 0
        if gpu_visible:
            visible_count += 1
        if cpu_visible != gpu_visible:
            mismatches += 1
    var cpu_us := Time.get_ticks_usec() - cpu_started

    _free_rids(rd, [uniform_set, pipeline, sphere_buffer, plane_buffer, visibility_buffer, shader_rid])
    return {
        "supported": true,
        "count": count,
        "visible": visible_count,
        "mismatches": mismatches,
        "gpu_dispatch_us": gpu_us,
        "cpu_reference_us": cpu_us,
    }

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

static func _free_rids(rd: RenderingDevice, rids: Array) -> void:
    for rid_value in rids:
        if rid_value is RID and (rid_value as RID).is_valid():
            rd.free_rid(rid_value)
