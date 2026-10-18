extends SceneTree

const Probe = preload("res://scripts/gpu_indirect_multimesh_probe.gd")
const Lifecycle = preload("res://scripts/gpu_indirect_multimesh_lifecycle.gd")
const PROBE_COUNT := 8195
const SURFACE_COUNT := 2
const STRIDE_FLOATS := 20
const TIMEOUT_FRAMES := 240
const CLEANUP_TIMEOUT_FRAMES := 120
var failures := 0
var _mesh: ArrayMesh
var _multimesh := RID()
var _cleanup_mutex := Mutex.new()
var _cleanup_done := false
var _cleanup_result: Dictionary = {}

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("GPU_INDIRECT_MULTIMESH_TEST: " + message)

func _sphere(index: int) -> Vector4:
    return Vector4(float((index * 73) % 401) - 200.0, float((index * 151) % 301) - 150.0,
        float((index * 199) % 501) - 250.0, 0.5 + float(index % 9) * 0.35)

func _visible(sphere: Vector4) -> bool:
    return sphere.x + 50.0 >= -sphere.w and -sphere.x + 50.0 >= -sphere.w \
        and sphere.y + 50.0 >= -sphere.w and -sphere.y + 50.0 >= -sphere.w \
        and sphere.z + 50.0 >= -sphere.w and -sphere.z + 50.0 >= -sphere.w

func _expected_record(index: int) -> PackedFloat32Array:
    var sphere := _sphere(index)
    return PackedFloat32Array([
        1.0, 0.0, 0.0, sphere.x,
        0.0, 1.0, 0.0, sphere.y,
        0.0, 0.0, 1.0, sphere.z,
        float(index % 17) / 16.0,
        float(index % 13) / 12.0,
        float(index % 11) / 10.0,
        1.0,
        float(index),
        float(index % 7) / 6.0,
        float(index % 5) / 4.0,
        1.0,
    ])

func _make_two_surface_mesh() -> ArrayMesh:
    var mesh := ArrayMesh.new()
    var first := []
    first.resize(Mesh.ARRAY_MAX)
    first[Mesh.ARRAY_VERTEX] = PackedVector3Array([
        Vector3(-0.5, 0.0, 0.0), Vector3(0.5, 0.0, 0.0), Vector3(0.0, 1.0, 0.0)])
    first[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, first)

    var second := []
    second.resize(Mesh.ARRAY_MAX)
    second[Mesh.ARRAY_VERTEX] = PackedVector3Array([
        Vector3(-0.5, 0.0, 0.1), Vector3(0.0, 1.0, 0.1), Vector3(0.5, 0.0, 0.1)])
    second[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, second)
    return mesh

func _run() -> void:
    _mesh = _make_two_surface_mesh()
    _check(_mesh.get_surface_count() == SURFACE_COUNT, "test mesh did not create two indexed surfaces")
    _multimesh = RenderingServer.multimesh_create()

    # Allocate the exact record shape used by Yardman roadside vegetation:
    # Transform3D + color + custom data, with indirect drawing enabled.
    RenderingServer.multimesh_allocate_data(_multimesh, PROBE_COUNT,
        RenderingServer.MULTIMESH_TRANSFORM_3D, true, true, true)
    RenderingServer.multimesh_set_mesh(_multimesh, _mesh.get_rid())
    RenderingServer.multimesh_set_custom_aabb(_multimesh, AABB(Vector3(-260, -210, -310), Vector3(520, 420, 620)))

    _check(RenderingServer.multimesh_get_buffer_rd_rid(_multimesh).is_valid(),
        "instance RD buffer did not initialize after indirect allocation")
    _check(RenderingServer.multimesh_get_command_buffer_rd_rid(_multimesh).is_valid(),
        "command RD buffer did not initialize after post-allocation mesh bind")

    var probe := Probe.new()
    _check(probe.begin(_multimesh, PROBE_COUNT, SURFACE_COUNT), "probe did not start")
    var frames := 0
    while not probe.is_done() and frames < TIMEOUT_FRAMES:
        frames += 1
        await process_frame

    _check(probe.is_done(), "render-thread probe timed out")
    var result := probe.result()
    _check(bool(result.get("supported", false)), "global RD indirect path unavailable: " + str(result.get("reason", "unknown")))
    if bool(result.get("supported", false)):
        _check(int(result.get("stride_floats", 0)) == STRIDE_FLOATS,
            "probe stride differs from Yardman Transform3D+color+custom layout")
        _check(int(result.get("surface_count", 0)) == SURFACE_COUNT,
            "probe did not preserve requested surface count")

        var expected_count := 0
        var expected_ids: Dictionary = {}
        for index in range(PROBE_COUNT):
            if _visible(_sphere(index)):
                expected_count += 1
                expected_ids[index] = true

        _check(int(result.get("visible", -1)) == expected_count,
            "GPU visible count differs from CPU reference")

        var commands: PackedInt32Array = result.get("commands", PackedInt32Array())
        _check(commands.size() >= SURFACE_COUNT * 5,
            "indirect command buffer does not expose five words per indexed surface")
        if commands.size() >= SURFACE_COUNT * 5:
            for surface in range(SURFACE_COUNT):
                _check(commands[surface * 5 + 1] == expected_count,
                    "surface %d indirect instanceCount differs from visible count" % surface)

        # Atomic compaction order is intentionally undefined. Validate records
        # by their custom-data source ID instead of by destination slot.
        var records: PackedFloat32Array = result.get("records", PackedFloat32Array())
        _check(records.size() == expected_count * STRIDE_FLOATS,
            "compacted full-record byte count differs from visible count")
        var seen_ids: Dictionary = {}
        if records.size() == expected_count * STRIDE_FLOATS:
            for slot in range(expected_count):
                var base := slot * STRIDE_FLOATS
                var source_id := int(round(records[base + 16]))
                _check(expected_ids.has(source_id),
                    "compacted record contains a culled or invalid source identity")
                _check(not seen_ids.has(source_id),
                    "compacted record duplicated a source identity")
                seen_ids[source_id] = true
                if expected_ids.has(source_id):
                    var expected := _expected_record(source_id)
                    for component in range(STRIDE_FLOATS):
                        _check(is_equal_approx(records[base + component], expected[component]),
                            "source %d component %d changed during full-record compaction" % [source_id, component])
            _check(seen_ids.size() == expected_ids.size(),
                "compaction omitted one or more visible source records")

        print("YARDMAN_GPU_INDIRECT_MULTIMESH_METRICS count=%d visible=%d surfaces=%d stride=%d roundtrip_us=%d" % [
            PROBE_COUNT, expected_count, SURFACE_COUNT, STRIDE_FLOATS, int(result.get("roundtrip_us", -1))])

    await _free_multimesh_and_sync()
    if Lifecycle.requires_472_command_buffer_workaround():
        _check(bool(_cleanup_result.get("manual_command_free", false)),
            "Godot 4.7.2 command-buffer leak workaround did not execute")
    _mesh = null
    await process_frame
    print("YARDMAN_GPU_INDIRECT_MULTIMESH_TEST %s global_rd=1 full_record=1 multsurface=1 barrier=1 indirect_count=1 cleanup=1 no_runtime_readback=1" % ("PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)

func _free_multimesh_and_sync() -> void:
    if not _multimesh.is_valid():
        return
    var rid_to_free := _multimesh
    _multimesh = RID()
    _cleanup_mutex.lock()
    _cleanup_done = false
    _cleanup_result = {}
    _cleanup_mutex.unlock()
    RenderingServer.call_on_render_thread(_free_multimesh_render_thread.bind(rid_to_free))

    var cleanup_frames := 0
    while not _is_cleanup_done() and cleanup_frames < CLEANUP_TIMEOUT_FRAMES:
        cleanup_frames += 1
        await process_frame
    _check(_is_cleanup_done(), "render-thread MultiMesh cleanup timed out")
    RenderingServer.force_sync()
    await process_frame

func _free_multimesh_render_thread(rid_to_free: RID) -> void:
    var result := Lifecycle.free_on_render_thread(rid_to_free)
    _cleanup_mutex.lock()
    _cleanup_result = result
    _cleanup_done = true
    _cleanup_mutex.unlock()

func _is_cleanup_done() -> bool:
    _cleanup_mutex.lock()
    var value := _cleanup_done
    _cleanup_mutex.unlock()
    return value
