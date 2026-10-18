extends RefCounted
class_name YardmanGPURoadsideHZBProbe

const Shared = preload("res://scripts/gpu_roadside_shared_probe.gd")
const HZB = preload("res://scripts/gpu_hzb_probe.gd")
const CULL_SHADER = preload("res://shaders/gpu_hzb_cull.glsl")
const COMPACT_SHADER = preload("res://shaders/gpu_roadside_hzb_compact.glsl")
const FINALIZE_SHADER = preload("res://shaders/gpu_roadside_shared_finalize.glsl")

const WIDTH := 128
const HEIGHT := 72
const FOV_Y_DEGREES := 70.0
const NEAR_DISTANCE := 0.1
const FAR_DISTANCE := 120.0
const CAMERA_POSITION := Vector3(0.0, 0.0, 50.0)
const SOURCE_STRIDE_FLOATS := 8
const DESTINATION_STRIDE_FLOATS := 20
const CANDIDATE_STRIDE_FLOATS := 5
const CAMERA_PARAM_FLOATS := 28
const LOCAL_SIZE_X := 64
const DEPTH_BIAS_M := 0.05
const SCREEN_MARGIN_PIXELS := 1.5

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

static func camera_transform() -> Transform3D:
    return Transform3D(Basis.IDENTITY, CAMERA_POSITION)

static func camera_planes() -> Array:
    return Shared.perspective_frustum(camera_transform(), FOV_Y_DEGREES,
        float(WIDTH) / float(HEIGHT), NEAR_DISTANCE, FAR_DISTANCE)

static func candidate_for_source(source: PackedFloat32Array) -> PackedFloat32Array:
    var position := Vector3(source[0], source[1], source[2])
    var scale := source[4]
    var radius := maxf(0.25, scale * 2.0)
    var view := position - CAMERA_POSITION
    var depth := -view.z
    if depth <= 0.0001:
        return PackedFloat32Array([-2.0, -2.0, -1.0, -1.0, -1.0])

    var tan_y := tan(deg_to_rad(FOV_Y_DEGREES) * 0.5)
    var tan_x := tan_y * (float(WIDTH) / float(HEIGHT))
    var nearest_depth := depth - radius
    if nearest_depth <= NEAR_DISTANCE:
        return PackedFloat32Array([-2.0, -2.0, -1.0, -1.0, -1.0])

    var ndc_x := view.x / (depth * tan_x)
    var ndc_y := view.y / (depth * tan_y)
    # Dividing the radius by the sphere's nearest depth deliberately expands
    # the screen rectangle beyond the exact projected sphere silhouette.
    var radius_ndc_x := radius / (nearest_depth * tan_x)
    var radius_ndc_y := radius / (nearest_depth * tan_y)
    var center_x := (ndc_x * 0.5 + 0.5) * float(WIDTH)
    var center_y := (0.5 - ndc_y * 0.5) * float(HEIGHT)
    var half_x := radius_ndc_x * 0.5 * float(WIDTH) + SCREEN_MARGIN_PIXELS
    var half_y := radius_ndc_y * 0.5 * float(HEIGHT) + SCREEN_MARGIN_PIXELS
    return PackedFloat32Array([
        center_x - half_x, center_y - half_y,
        center_x + half_x, center_y + half_y,
        nearest_depth,
    ])

static func brute_visible(candidate: PackedFloat32Array,
        base_depth: PackedFloat32Array) -> bool:
    var min_x := candidate[0]
    var min_y := candidate[1]
    var max_x := candidate[2]
    var max_y := candidate[3]
    var near_depth := candidate[4]
    if near_depth <= 0.0 or max_x < 0.0 or max_y < 0.0 \
            or min_x >= float(WIDTH) or min_y >= float(HEIGHT):
        return true

    var x0 := clampi(int(floor(maxf(min_x, 0.0))), 0, WIDTH - 1)
    var y0 := clampi(int(floor(maxf(min_y, 0.0))), 0, HEIGHT - 1)
    var x1 := clampi(int(floor(minf(max_x, float(WIDTH - 1)))), 0, WIDTH - 1)
    var y1 := clampi(int(floor(minf(max_y, float(HEIGHT - 1)))), 0, HEIGHT - 1)
    var maximum_depth := 0.0
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            maximum_depth = maxf(maximum_depth, base_depth[y * WIDTH + x])
    return not (maximum_depth + DEPTH_BIAS_M < near_depth)

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
    for rid_value in [near_buffer, far_buffer, grass_buffer,
            near_commands, far_commands, grass_commands]:
        if not (rid_value as RID).is_valid():
            _finish({"supported": false, "reason": "roadside MultiMesh RD buffers unavailable"})
            return

    var cull_shader := rd.shader_create_from_spirv(CULL_SHADER.get_spirv())
    var compact_shader := rd.shader_create_from_spirv(COMPACT_SHADER.get_spirv())
    var finalize_shader := rd.shader_create_from_spirv(FINALIZE_SHADER.get_spirv())
    var owned: Array = [cull_shader, compact_shader, finalize_shader]
    if not cull_shader.is_valid() or not compact_shader.is_valid() or not finalize_shader.is_valid():
        _free_owned(rd, owned)
        _finish({"supported": false, "reason": "roadside HZB shader creation failed"})
        return

    var source_values := PackedFloat32Array()
    var candidate_values := PackedFloat32Array()
    source_values.resize(count * SOURCE_STRIDE_FLOATS)
    candidate_values.resize(count * CANDIDATE_STRIDE_FLOATS)
    for index in range(count):
        var source := Shared.source_record(index, count)
        var candidate := candidate_for_source(source)
        var source_base := index * SOURCE_STRIDE_FLOATS
        var candidate_base := index * CANDIDATE_STRIDE_FLOATS
        for component in range(SOURCE_STRIDE_FLOATS):
            source_values[source_base + component] = source[component]
        for component in range(CANDIDATE_STRIDE_FLOATS):
            candidate_values[candidate_base + component] = candidate[component]

    var base_depth := HZB.build_depth_field(WIDTH, HEIGHT)
    var pyramid_pack := _build_pyramid(base_depth, WIDTH, HEIGHT)
    var pyramid_values: PackedFloat32Array = pyramid_pack.values
    var level_values: PackedInt32Array = pyramid_pack.level_values
    var level_count := int(pyramid_pack.level_count)
    var visibility_values := PackedInt32Array()
    visibility_values.resize(count)
    visibility_values.fill(1)

    var camera_values := _encode_camera(CAMERA_POSITION, camera_planes())
    var zero_counts := PackedInt32Array([0, 0, 0, 0]).to_byte_array()
    var count_params := PackedInt32Array([count, 0, 0, 0]).to_byte_array()
    var ranges := PackedFloat32Array([
        Shared.NEAR_END, Shared.FAR_BEGIN, Shared.FAR_END, Shared.GRASS_END]).to_byte_array()
    var surface_params := PackedInt32Array([
        surface_count, surface_count, surface_count, 0]).to_byte_array()
    var cull_params := PackedInt32Array([count, WIDTH, HEIGHT, level_count]).to_byte_array()

    var source_buffer := rd.storage_buffer_create(source_values.to_byte_array().size(), source_values.to_byte_array())
    var candidate_buffer := rd.storage_buffer_create(candidate_values.to_byte_array().size(), candidate_values.to_byte_array())
    var pyramid_buffer := rd.storage_buffer_create(pyramid_values.to_byte_array().size(), pyramid_values.to_byte_array())
    var level_buffer := rd.storage_buffer_create(level_values.to_byte_array().size(), level_values.to_byte_array())
    var visibility_buffer := rd.storage_buffer_create(visibility_values.to_byte_array().size(), visibility_values.to_byte_array())
    var cull_param_buffer := rd.storage_buffer_create(cull_params.size(), cull_params)
    var counter_buffer := rd.storage_buffer_create(zero_counts.size(), zero_counts)
    var count_buffer := rd.storage_buffer_create(count_params.size(), count_params)
    var range_buffer := rd.storage_buffer_create(ranges.size(), ranges)
    var surface_buffer := rd.storage_buffer_create(surface_params.size(), surface_params)
    var camera_buffer := rd.storage_buffer_create(camera_values.to_byte_array().size(), camera_values.to_byte_array())
    owned.append_array([source_buffer, candidate_buffer, pyramid_buffer, level_buffer,
        visibility_buffer, cull_param_buffer, counter_buffer, count_buffer,
        range_buffer, surface_buffer, camera_buffer])
    for rid_value in [source_buffer, candidate_buffer, pyramid_buffer, level_buffer,
            visibility_buffer, cull_param_buffer, counter_buffer, count_buffer,
            range_buffer, surface_buffer, camera_buffer]:
        if not (rid_value as RID).is_valid():
            _free_owned(rd, owned)
            _finish({"supported": false, "reason": "roadside HZB storage buffer creation failed"})
            return

    var cull_set := rd.uniform_set_create([
        _storage_uniform(0, pyramid_buffer),
        _storage_uniform(1, level_buffer),
        _storage_uniform(2, candidate_buffer),
        _storage_uniform(3, visibility_buffer),
        _storage_uniform(4, cull_param_buffer),
    ], cull_shader, 0)
    var compact_set := rd.uniform_set_create([
        _storage_uniform(0, source_buffer),
        _storage_uniform(1, near_buffer),
        _storage_uniform(2, far_buffer),
        _storage_uniform(3, grass_buffer),
        _storage_uniform(4, counter_buffer),
        _storage_uniform(5, count_buffer),
        _storage_uniform(6, range_buffer),
        _storage_uniform(7, camera_buffer),
        _storage_uniform(8, visibility_buffer),
    ], compact_shader, 0)
    var finalize_set := rd.uniform_set_create([
        _storage_uniform(0, counter_buffer),
        _storage_uniform(1, near_commands),
        _storage_uniform(2, far_commands),
        _storage_uniform(3, grass_commands),
        _storage_uniform(4, surface_buffer),
    ], finalize_shader, 0)
    var cull_pipeline := rd.compute_pipeline_create(cull_shader)
    var compact_pipeline := rd.compute_pipeline_create(compact_shader)
    var finalize_pipeline := rd.compute_pipeline_create(finalize_shader)
    owned.append_array([cull_set, compact_set, finalize_set,
        cull_pipeline, compact_pipeline, finalize_pipeline])
    if not cull_set.is_valid() or not compact_set.is_valid() or not finalize_set.is_valid() \
            or not cull_pipeline.is_valid() or not compact_pipeline.is_valid() \
            or not finalize_pipeline.is_valid():
        _free_owned(rd, owned)
        _finish({"supported": false, "reason": "roadside HZB pipeline creation failed"})
        return

    rd.buffer_update(counter_buffer, 0, zero_counts.size(), zero_counts)
    var started_us := Time.get_ticks_usec()
    var compute_list := rd.compute_list_begin()
    rd.compute_list_bind_compute_pipeline(compute_list, cull_pipeline)
    rd.compute_list_bind_uniform_set(compute_list, cull_set, 0)
    rd.compute_list_dispatch(compute_list, ceili(float(count) / float(LOCAL_SIZE_X)), 1, 1)
    rd.compute_list_add_barrier(compute_list)
    rd.compute_list_bind_compute_pipeline(compute_list, compact_pipeline)
    rd.compute_list_bind_uniform_set(compute_list, compact_set, 0)
    rd.compute_list_dispatch(compute_list, ceili(float(count) / float(LOCAL_SIZE_X)), 1, 1)
    rd.compute_list_add_barrier(compute_list)
    rd.compute_list_bind_compute_pipeline(compute_list, finalize_pipeline)
    rd.compute_list_bind_uniform_set(compute_list, finalize_set, 0)
    rd.compute_list_dispatch(compute_list, ceili(float(surface_count) / float(LOCAL_SIZE_X)), 1, 1)
    rd.compute_list_end()

    # Validation readback only; the production path keeps this chain GPU resident.
    var gpu_visibility := rd.buffer_get_data(visibility_buffer).to_int32_array()
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

    var result_value := {
        "supported": true,
        "count": count,
        "surface_count": surface_count,
        "base_depth": base_depth,
        "candidates": candidate_values,
        "visibility": gpu_visibility,
        "near_count": near_count,
        "far_count": far_count,
        "grass_count": grass_count,
        "near_records": _prefix(near_values, near_count * DESTINATION_STRIDE_FLOATS),
        "far_records": _prefix(far_values, far_count * DESTINATION_STRIDE_FLOATS),
        "grass_records": _prefix(grass_values, grass_count * DESTINATION_STRIDE_FLOATS),
        "near_commands": near_command_values,
        "far_commands": far_command_values,
        "grass_commands": grass_command_values,
        "pyramid_bytes": pyramid_values.size() * 4,
        "roundtrip_us": elapsed_us,
    }
    _free_owned(rd, owned)
    _finish(result_value)

static func _build_pyramid(base_depth: PackedFloat32Array,
        width: int, height: int) -> Dictionary:
    var all_values := PackedFloat32Array()
    var level_values := PackedInt32Array()
    var current := base_depth.duplicate()
    var current_width := width
    var current_height := height
    var offset := 0
    var level_count := 0
    while true:
        for value in current:
            all_values.append(value)
        level_values.append(offset)
        level_values.append(current_width)
        level_values.append(current_height)
        level_values.append(0)
        level_count += 1
        offset += current.size()
        if current_width == 1 and current_height == 1:
            break
        var next_width := maxi(1, (current_width + 1) / 2)
        var next_height := maxi(1, (current_height + 1) / 2)
        var next := PackedFloat32Array()
        next.resize(next_width * next_height)
        for y in range(next_height):
            for x in range(next_width):
                var maximum := 0.0
                for oy in range(2):
                    for ox in range(2):
                        var sx := mini(x * 2 + ox, current_width - 1)
                        var sy := mini(y * 2 + oy, current_height - 1)
                        maximum = maxf(maximum, current[sy * current_width + sx])
                next[y * next_width + x] = maximum
        current = next
        current_width = next_width
        current_height = next_height
    return {"values": all_values, "level_values": level_values, "level_count": level_count}

static func _encode_camera(camera_position: Vector3, planes: Array) -> PackedFloat32Array:
    var values := PackedFloat32Array()
    values.resize(CAMERA_PARAM_FLOATS)
    values[0] = camera_position.x
    values[1] = camera_position.y
    values[2] = camera_position.z
    values[3] = 1.0
    for index in range(6):
        var plane: Vector4 = planes[index]
        var base := 4 + index * 4
        values[base + 0] = plane.x
        values[base + 1] = plane.y
        values[base + 2] = plane.z
        values[base + 3] = plane.w
    return values

static func _storage_uniform(binding: int, rid: RID) -> RDUniform:
    var uniform := RDUniform.new()
    uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    uniform.binding = binding
    uniform.add_id(rid)
    return uniform

static func _prefix(values: PackedFloat32Array, requested: int) -> PackedFloat32Array:
    var size := clampi(requested, 0, values.size())
    var result := PackedFloat32Array()
    result.resize(size)
    for index in range(size):
        result[index] = values[index]
    return result

static func _free_owned(rd: RenderingDevice, rids: Array) -> void:
    for index in range(rids.size() - 1, -1, -1):
        var rid_value = rids[index]
        if rid_value is RID and (rid_value as RID).is_valid():
            rd.free_rid(rid_value)

func _finish(value: Dictionary) -> void:
    _mutex.lock()
    _result = value
    _done = true
    _mutex.unlock()
