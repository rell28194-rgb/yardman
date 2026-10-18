extends RefCounted
class_name YardmanGPUIndirectCluster

const Capabilities = preload("res://scripts/gpu_driven_capabilities.gd")
const Contract = preload("res://scripts/gpu_indirect_contract.gd")
const SHADER_PATH := "res://shaders/gpu_multimesh_indirect.glsl"
const LOCAL_SIZE_X := 64
const PLANE_FLOATS := 24
const FLOAT_BYTES := 4

var _state := "new"
var _reason := ""
var _capacity := 0
var _cluster_aabb := AABB()
var _mesh: Mesh
var _spirv: RDShaderSPIRV

var _multimesh := RID()
var _instance := RID()
var _mm_buffer := RID()
var _command_buffer := RID()

var _shader := RID()
var _sphere_buffer := RID()
var _plane_buffer := RID()
var _params_buffer := RID()
var _uniform_set := RID()
var _pipeline := RID()

var _submitted_dispatches := 0
var _last_candidate_count := 0
var _retire_requested := false

func initialize(mesh: Mesh, capacity: int, cluster_aabb: AABB) -> Dictionary:
    if _state != "new":
        return _fail_main("already_initialized")

    var capability := Capabilities.snapshot()
    if not bool(capability.get("gpu_driven_candidate", false)):
        return _fail_main("capability:" + str(capability.get("fallback_reason", "unsupported")))

    var contract := Contract.validate(
        mesh, RenderingServer.MULTIMESH_TRANSFORM_3D, false, false)
    if not bool(contract.get("valid", false)):
        return _fail_main("contract:" + str(contract.get("reason", "unsupported")))
    if capacity <= 0 or capacity > 1_048_576:
        return _fail_main("capacity")
    if not _valid_aabb(cluster_aabb):
        return _fail_main("cluster_aabb")

    var shader_file := load(SHADER_PATH) as RDShaderFile
    if shader_file == null:
        return _fail_main("shader_resource")

    _mesh = mesh
    _capacity = capacity
    _cluster_aabb = cluster_aabb
    _spirv = shader_file.get_spirv()
    _multimesh = RenderingServer.multimesh_create()
    RenderingServer.multimesh_allocate_data(
        _multimesh, _capacity, RenderingServer.MULTIMESH_TRANSFORM_3D,
        false, false, true)
    RenderingServer.multimesh_set_mesh(_multimesh, _mesh.get_rid())
    _state = "initializing"
    RenderingServer.call_on_render_thread(Callable(self, "_render_thread_initialize"))
    return snapshot()

func attach_to_scenario(scenario: RID) -> bool:
    if _state not in ["initializing", "ready"] or not scenario.is_valid() \
            or not _multimesh.is_valid() or _instance.is_valid():
        return false
    _instance = RenderingServer.instance_create()
    RenderingServer.instance_set_base(_instance, _multimesh)
    RenderingServer.instance_set_scenario(_instance, scenario)
    # GPU-written transforms do not update Godot's CPU-derived MultiMesh AABB.
    # Every cluster therefore requires a conservative explicit world-local AABB.
    RenderingServer.instance_set_custom_aabb(_instance, _cluster_aabb)
    return true

func set_instance_transform(transform: Transform3D) -> bool:
    if not _instance.is_valid():
        return false
    RenderingServer.instance_set_transform(_instance, transform)
    return true

func dispatch(spheres: PackedFloat32Array, planes: PackedFloat32Array) -> bool:
    if _state != "ready" or _retire_requested:
        return false
    if spheres.size() % 4 != 0 or planes.size() != PLANE_FLOATS:
        return false
    var count := spheres.size() / 4
    if count > _capacity:
        return false
    for value in spheres:
        if not is_finite(value):
            return false
    for value in planes:
        if not is_finite(value):
            return false

    _last_candidate_count = count
    var sphere_bytes := spheres.to_byte_array()
    var plane_bytes := planes.to_byte_array()
    RenderingServer.call_on_render_thread(
        Callable(self, "_render_thread_dispatch").bind(sphere_bytes, plane_bytes, count))
    _submitted_dispatches += 1
    return true

func retire() -> void:
    if _retire_requested or _state in ["retired", "new"]:
        return
    _retire_requested = true
    _state = "retiring"
    if _instance.is_valid():
        RenderingServer.free_rid(_instance)
        _instance = RID()
    RenderingServer.call_on_render_thread(Callable(self, "_render_thread_retire"))

func is_ready() -> bool:
    return _state == "ready"

func is_retired() -> bool:
    return _state == "retired"

func multimesh_rid() -> RID:
    return _multimesh

func snapshot() -> Dictionary:
    return {
        "state": _state,
        "reason": _reason,
        "ready": _state == "ready",
        "fallback_required": _state == "failed",
        "capacity": _capacity,
        "submitted_dispatches": _submitted_dispatches,
        "last_candidate_count": _last_candidate_count,
        "instance_attached": _instance.is_valid(),
        "godot_472_command_workaround": _needs_472_command_workaround(),
    }

func _render_thread_initialize() -> void:
    var rd := RenderingServer.get_rendering_device()
    if rd == null:
        _fail_render_thread("rendering_device")
        return
    _mm_buffer = RenderingServer.multimesh_get_buffer_rd_rid(_multimesh)
    _command_buffer = RenderingServer.multimesh_get_command_buffer_rd_rid(_multimesh)
    if not _mm_buffer.is_valid() or not _command_buffer.is_valid():
        _fail_render_thread("multimesh_buffers")
        return

    _shader = rd.shader_create_from_spirv(_spirv)
    if not _shader.is_valid():
        _fail_render_thread("shader")
        return
    _sphere_buffer = rd.storage_buffer_create(_capacity * 4 * FLOAT_BYTES)
    _plane_buffer = rd.storage_buffer_create(PLANE_FLOATS * FLOAT_BYTES)
    _params_buffer = rd.storage_buffer_create(FLOAT_BYTES)
    if not _sphere_buffer.is_valid() or not _plane_buffer.is_valid() or not _params_buffer.is_valid():
        _free_compute_resources(rd)
        _fail_render_thread("storage_buffers")
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
        _free_compute_resources(rd)
        _fail_render_thread("pipeline")
        return
    _state = "ready"

func _render_thread_dispatch(sphere_bytes: PackedByteArray,
        plane_bytes: PackedByteArray, count: int) -> void:
    if _state != "ready":
        return
    var rd := RenderingServer.get_rendering_device()
    if rd == null:
        _fail_render_thread("rendering_device_lost")
        return

    if not sphere_bytes.is_empty():
        rd.buffer_update(_sphere_buffer, 0, sphere_bytes.size(), sphere_bytes)
    rd.buffer_update(_plane_buffer, 0, plane_bytes.size(), plane_bytes)
    rd.buffer_update(_params_buffer, 0, FLOAT_BYTES, PackedInt32Array([count]).to_byte_array())
    # Preserve mesh-authored indexCount/firstIndex/baseVertex/firstInstance.
    # Only instanceCount (word 1, byte offset 4) is reset by Yardman.
    rd.buffer_update(_command_buffer, FLOAT_BYTES, FLOAT_BYTES,
        PackedInt32Array([0]).to_byte_array())
    if count == 0:
        return

    var compute_list := rd.compute_list_begin()
    rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)
    rd.compute_list_bind_uniform_set(compute_list, _uniform_set, 0)
    rd.compute_list_dispatch(compute_list,
        ceili(float(count) / float(LOCAL_SIZE_X)), 1, 1)
    rd.compute_list_end()
    # Global RD submission is owned by Godot's render loop. Never call submit()
    # or sync() here; both are local-device-only APIs.

func _render_thread_retire() -> void:
    var rd := RenderingServer.get_rendering_device()
    if rd != null:
        _free_compute_resources(rd)
        if _needs_472_command_workaround() and _command_buffer.is_valid():
            # Godot 4.7.2 RD MultiMesh reallocation drops this RID without
            # freeing its storage buffer. Scope the workaround to that exact
            # engine version so a future engine-side fix cannot double-free it.
            rd.free_rid(_command_buffer)
    _command_buffer = RID()
    _mm_buffer = RID()
    Callable(self, "_finish_retire_main_thread").call_deferred()

func _finish_retire_main_thread() -> void:
    if _multimesh.is_valid():
        RenderingServer.multimesh_allocate_data(
            _multimesh, 0, RenderingServer.MULTIMESH_TRANSFORM_3D,
            false, false, false)
        RenderingServer.free_rid(_multimesh)
        _multimesh = RID()
    _mesh = null
    _spirv = null
    _state = "retired"

func _free_compute_resources(rd: RenderingDevice) -> void:
    # Descriptor/pipeline teardown precedes buffers so dependency invalidation
    # cannot turn later explicit frees into invalid-ID or double-free errors.
    for rid_value in [_uniform_set, _pipeline, _sphere_buffer,
            _plane_buffer, _params_buffer, _shader]:
        if rid_value.is_valid():
            rd.free_rid(rid_value)
    _uniform_set = RID()
    _pipeline = RID()
    _sphere_buffer = RID()
    _plane_buffer = RID()
    _params_buffer = RID()
    _shader = RID()

func _fail_main(reason: String) -> Dictionary:
    _reason = reason
    _state = "failed"
    return snapshot()

func _fail_render_thread(reason: String) -> void:
    _reason = reason
    _state = "failed"

func _storage_uniform(binding: int, rid: RID) -> RDUniform:
    var uniform := RDUniform.new()
    uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    uniform.binding = binding
    uniform.add_id(rid)
    return uniform

func _valid_aabb(bounds: AABB) -> bool:
    return bounds.position.is_finite() and bounds.size.is_finite() \
        and bounds.size.x > 0.0 and bounds.size.y > 0.0 and bounds.size.z > 0.0

func _needs_472_command_workaround() -> bool:
    var version := Engine.get_version_info()
    return int(version.get("major", 0)) == 4 \
        and int(version.get("minor", 0)) == 7 \
        and int(version.get("patch", 0)) == 2
