extends RefCounted
class_name YardmanGPUIndirectMultiMeshProbe

const SHADER_FILE = preload("res://shaders/gpu_indirect_multimesh.glsl")
const LOCAL_SIZE_X := 64

var _mutex := Mutex.new()
var _done := false
var _started := false
var _result: Dictionary = {}

func begin(multimesh: RID, count: int) -> bool:
    _mutex.lock()
    if _started:
        _mutex.unlock()
        return false
    _started = true
    _mutex.unlock()
    RenderingServer.call_on_render_thread(_run_render.bind(multimesh, clampi(count, 64, 262144)))
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

func _run_render(multimesh: RID, count: int) -> void:
    var rd := RenderingServer.get_rendering_device()
    if rd == null:
        _finish({"supported": false, "reason": "global RenderingDevice unavailable"})
        return

    var instance_buffer := RenderingServer.multimesh_get_buffer_rd_rid(multimesh)
    var command_buffer := RenderingServer.multimesh_get_command_buffer_rd_rid(multimesh)
    if not instance_buffer.is_valid() or not command_buffer.is_valid():
        _finish({"supported": false, "reason": "MultiMesh RD buffers unavailable"})
        return

    var shader_rid := rd.shader_create_from_spirv(SHADER_FILE.get_spirv())
    if not shader_rid.is_valid():
        _finish({"supported": false, "reason": "indirect compute shader creation failed"})
        return

    var sphere_values := PackedFloat32Array()
    sphere_values.resize(count * 4)
    for index in range(count):
        var base := index * 4
        sphere_values[base] = float((index * 73) % 401) - 200.0
        sphere_values[base + 1] = float((index * 151) % 301) - 150.0
        sphere_values[base + 2] = float((index * 199) % 501) - 250.0
        sphere_values[base + 3] = 0.5 + float(index % 9) * 0.35

    var sphere_bytes := sphere_values.to_byte_array()
    var params_bytes := PackedInt32Array([count]).to_byte_array()
    var sphere_buffer := rd.storage_buffer_create(sphere_bytes.size(), sphere_bytes)
    var params_buffer := rd.storage_buffer_create(params_bytes.size(), params_bytes)
    if not sphere_buffer.is_valid() or not params_buffer.is_valid():
        _free_owned(rd, [sphere_buffer, params_buffer, shader_rid])
        _finish({"supported": false, "reason": "probe storage buffer creation failed"})
        return

    var uniform_set := rd.uniform_set_create([
        _storage_uniform(0, sphere_buffer),
        _storage_uniform(1, params_buffer),
        _storage_uniform(2, instance_buffer),
        _storage_uniform(3, command_buffer),
    ], shader_rid, 0)
    var pipeline := rd.compute_pipeline_create(shader_rid)
    if not uniform_set.is_valid() or not pipeline.is_valid():
        _free_owned(rd, [uniform_set, pipeline, sphere_buffer, params_buffer, shader_rid])
        _finish({"supported": false, "reason": "indirect compute pipeline creation failed"})
        return

    var zero := PackedInt32Array([0]).to_byte_array()
    rd.buffer_update(command_buffer, 4, zero.size(), zero)

    var started_us := Time.get_ticks_usec()
    var compute_list := rd.compute_list_begin()
    rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
    rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
    rd.compute_list_dispatch(compute_list, ceili(float(count) / float(LOCAL_SIZE_X)), 1, 1)
    rd.compute_list_end()

    # Validation-only readback. Production use consumes these RenderingServer-owned
    # buffers directly and must not synchronously read visibility results on CPU.
    var command_values := rd.buffer_get_data(command_buffer).to_int32_array()
    var instance_values := rd.buffer_get_data(instance_buffer).to_float32_array()
    var elapsed_us := Time.get_ticks_usec() - started_us
    var visible_count := int(command_values[1]) if command_values.size() > 1 else -1
    var origins := PackedVector3Array()
    if visible_count >= 0 and instance_values.size() >= visible_count * 12:
        origins.resize(visible_count)
        for slot in range(visible_count):
            var base := slot * 12
            origins[slot] = Vector3(instance_values[base + 3], instance_values[base + 7], instance_values[base + 11])

    _free_owned(rd, [uniform_set, pipeline, sphere_buffer, params_buffer, shader_rid])
    _finish({"supported": true, "count": count, "visible": visible_count, "origins": origins,
        "roundtrip_us": elapsed_us, "instance_buffer_valid": instance_buffer.is_valid(),
        "command_buffer_valid": command_buffer.is_valid()})

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
