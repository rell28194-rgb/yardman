extends RefCounted
class_name YardmanGPUHZBProbe

const REDUCE_SHADER_PATH := "res://shaders/gpu_hzb_reduce.glsl"
const CULL_SHADER_PATH := "res://shaders/gpu_hzb_cull.glsl"
const REDUCE_LOCAL_X := 8
const REDUCE_LOCAL_Y := 8
const CULL_LOCAL_X := 64
const CANDIDATE_STRIDE := 5
const FAR_DEPTH_M := 1000.0
const DEPTH_BIAS_M := 0.05

static func run_probe(width: int = 128, height: int = 72, candidate_count: int = 4096) -> Dictionary:
    width = clampi(width, 32, 1024)
    height = clampi(height, 32, 1024)
    candidate_count = clampi(candidate_count, 256, 65536)
    var rd := RenderingServer.create_local_rendering_device()
    if rd == null:
        return {"supported": false, "reason": "local RenderingDevice unavailable"}

    var reduce_file := load(REDUCE_SHADER_PATH) as RDShaderFile
    var cull_file := load(CULL_SHADER_PATH) as RDShaderFile
    if reduce_file == null or cull_file == null:
        rd.free()
        return {"supported": false, "reason": "HZB compute shader resource unavailable"}
    var reduce_shader := rd.shader_create_from_spirv(reduce_file.get_spirv())
    var cull_shader := rd.shader_create_from_spirv(cull_file.get_spirv())
    var owned: Array = [reduce_shader, cull_shader]
    if not reduce_shader.is_valid() or not cull_shader.is_valid():
        _free_rids(rd, owned)
        rd.free()
        return {"supported": false, "reason": "HZB shader creation failed"}

    var levels := _level_metadata(width, height)
    var pyramid_values := PackedFloat32Array()
    var total_values := 0
    for level in levels:
        total_values += int(level[1]) * int(level[2])
    pyramid_values.resize(total_values)
    pyramid_values.fill(FAR_DEPTH_M)
    var base_depth := build_depth_field(width, height)
    for index in range(base_depth.size()):
        pyramid_values[index] = base_depth[index]

    var level_values := PackedInt32Array()
    level_values.resize(levels.size() * 4)
    for index in range(levels.size()):
        var level: Vector3i = levels[index]
        var base := index * 4
        level_values[base + 0] = level.x
        level_values[base + 1] = level.y
        level_values[base + 2] = level.z
        level_values[base + 3] = 0

    var candidates := build_candidates(width, height, candidate_count)
    var output := PackedInt32Array()
    output.resize(candidate_count)
    output.fill(1)
    var cull_params := PackedInt32Array([candidate_count, width, height, levels.size()])

    var pyramid_buffer := rd.storage_buffer_create(pyramid_values.to_byte_array().size(), pyramid_values.to_byte_array())
    var level_buffer := rd.storage_buffer_create(level_values.to_byte_array().size(), level_values.to_byte_array())
    var candidate_buffer := rd.storage_buffer_create(candidates.to_byte_array().size(), candidates.to_byte_array())
    var output_buffer := rd.storage_buffer_create(output.to_byte_array().size(), output.to_byte_array())
    var cull_param_buffer := rd.storage_buffer_create(cull_params.to_byte_array().size(), cull_params.to_byte_array())
    owned.append_array([pyramid_buffer, level_buffer, candidate_buffer, output_buffer, cull_param_buffer])
    for rid_value in [pyramid_buffer, level_buffer, candidate_buffer, output_buffer, cull_param_buffer]:
        if not (rid_value as RID).is_valid():
            _free_rids(rd, owned)
            rd.free()
            return {"supported": false, "reason": "HZB storage buffer creation failed"}

    var reduce_pipeline := rd.compute_pipeline_create(reduce_shader)
    var cull_pipeline := rd.compute_pipeline_create(cull_shader)
    owned.append_array([reduce_pipeline, cull_pipeline])
    if not reduce_pipeline.is_valid() or not cull_pipeline.is_valid():
        _free_rids(rd, owned)
        rd.free()
        return {"supported": false, "reason": "HZB pipeline creation failed"}

    var reduce_sets: Array = []
    for level_index in range(1, levels.size()):
        var src: Vector3i = levels[level_index - 1]
        var dst: Vector3i = levels[level_index]
        var values := PackedInt32Array([
            src.x, src.y, src.z, dst.x,
            dst.y, dst.z, 0, 0,
        ])
        var param_buffer := rd.storage_buffer_create(values.to_byte_array().size(), values.to_byte_array())
        var uniform_set := rd.uniform_set_create([
            _storage_uniform(0, pyramid_buffer),
            _storage_uniform(1, param_buffer),
        ], reduce_shader, 0)
        owned.append_array([param_buffer, uniform_set])
        if not param_buffer.is_valid() or not uniform_set.is_valid():
            _free_rids(rd, owned)
            rd.free()
            return {"supported": false, "reason": "HZB reduction set creation failed"}
        reduce_sets.append({"set": uniform_set, "width": dst.y, "height": dst.z})

    var cull_set := rd.uniform_set_create([
        _storage_uniform(0, pyramid_buffer),
        _storage_uniform(1, level_buffer),
        _storage_uniform(2, candidate_buffer),
        _storage_uniform(3, output_buffer),
        _storage_uniform(4, cull_param_buffer),
    ], cull_shader, 0)
    owned.append(cull_set)
    if not cull_set.is_valid():
        _free_rids(rd, owned)
        rd.free()
        return {"supported": false, "reason": "HZB cull set creation failed"}

    var started_us := Time.get_ticks_usec()
    var compute_list := rd.compute_list_begin()
    for reduction in reduce_sets:
        rd.compute_list_bind_compute_pipeline(compute_list, reduce_pipeline)
        rd.compute_list_bind_uniform_set(compute_list, reduction.set, 0)
        rd.compute_list_dispatch(compute_list,
            ceili(float(reduction.width) / float(REDUCE_LOCAL_X)),
            ceili(float(reduction.height) / float(REDUCE_LOCAL_Y)), 1)
        rd.compute_list_add_barrier(compute_list)
    rd.compute_list_bind_compute_pipeline(compute_list, cull_pipeline)
    rd.compute_list_bind_uniform_set(compute_list, cull_set, 0)
    rd.compute_list_dispatch(compute_list, ceili(float(candidate_count) / float(CULL_LOCAL_X)), 1, 1)
    rd.compute_list_end()
    rd.submit()
    rd.sync()
    var roundtrip_us := Time.get_ticks_usec() - started_us

    var gpu_pyramid := rd.buffer_get_data(pyramid_buffer).to_float32_array()
    var gpu_visibility := rd.buffer_get_data(output_buffer).to_int32_array()
    var result := {
        "supported": true,
        "width": width,
        "height": height,
        "candidate_count": candidate_count,
        "levels": levels,
        "base_depth": base_depth,
        "pyramid": gpu_pyramid,
        "candidates": candidates,
        "visibility": gpu_visibility,
        "roundtrip_us": roundtrip_us,
        "pyramid_bytes": gpu_pyramid.size() * 4,
    }
    _free_rids(rd, owned)
    rd.free()
    return result

static func _level_metadata(width: int, height: int) -> Array[Vector3i]:
    var result: Array[Vector3i] = []
    var offset := 0
    var level_width := width
    var level_height := height
    while true:
        result.append(Vector3i(offset, level_width, level_height))
        offset += level_width * level_height
        if level_width == 1 and level_height == 1:
            break
        level_width = maxi(1, (level_width + 1) / 2)
        level_height = maxi(1, (level_height + 1) / 2)
    return result

static func build_depth_field(width: int, height: int) -> PackedFloat32Array:
    var values := PackedFloat32Array()
    values.resize(width * height)
    values.fill(FAR_DEPTH_M)
    for y in range(height):
        for x in range(width):
            var depth := FAR_DEPTH_M
            if y >= int(float(height) * 0.28):
                depth = 24.0
            if x >= int(float(width) * 0.08) and x < int(float(width) * 0.44) \
                    and y >= int(float(height) * 0.10) and y < int(float(height) * 0.84):
                depth = minf(depth, 8.0)
            if x >= int(float(width) * 0.52) and x < int(float(width) * 0.94) \
                    and y >= int(float(height) * 0.14) and y < int(float(height) * 0.72):
                depth = minf(depth, 14.0)
            if x >= int(float(width) * 0.45) and x < int(float(width) * 0.51):
                depth = FAR_DEPTH_M
            if x >= int(float(width) * 0.23) and x < int(float(width) * 0.31) \
                    and y >= int(float(height) * 0.42) and y < int(float(height) * 0.58):
                depth = FAR_DEPTH_M
            if x >= int(float(width) * 0.70) and x < int(float(width) * 0.76) \
                    and y >= int(float(height) * 0.32) and y < int(float(height) * 0.45):
                depth = 31.0
            values[y * width + x] = depth
    return values

static func build_candidates(width: int, height: int, count: int) -> PackedFloat32Array:
    var values := PackedFloat32Array()
    values.resize(count * CANDIDATE_STRIDE)
    for index in range(count):
        var center_x := float((index * 37) % width) + 0.25
        var center_y := float((index * 61) % height) + 0.25
        var half_width := 0.75 + float(index % 11) * 0.52
        var half_height := 0.75 + float((index * 3) % 9) * 0.47
        var near_depth := 5.0 + float((index * 17) % 500) * 0.10
        var base := index * CANDIDATE_STRIDE
        values[base + 0] = center_x - half_width
        values[base + 1] = center_y - half_height
        values[base + 2] = center_x + half_width
        values[base + 3] = center_y + half_height
        values[base + 4] = near_depth
    return values

static func _storage_uniform(binding: int, rid: RID) -> RDUniform:
    var uniform := RDUniform.new()
    uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    uniform.binding = binding
    uniform.add_id(rid)
    return uniform

static func _free_rids(rd: RenderingDevice, rids: Array) -> void:
    for index in range(rids.size() - 1, -1, -1):
        var rid_value = rids[index]
        if rid_value is RID and (rid_value as RID).is_valid():
            rd.free_rid(rid_value)
