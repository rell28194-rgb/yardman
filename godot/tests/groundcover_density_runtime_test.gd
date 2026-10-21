extends SceneTree

const Runtime = preload("res://scripts/groundcover_density_runtime.gd")

func _initialize() -> void:
    call_deferred("_run")

func _cleanup_and_fail(message: String, cell: MultiMeshInstance3D, runtime: Node, mesh: Resource, source: MultiMesh) -> void:
    if cell != null:
        cell.multimesh = null
        cell.free()
    if runtime != null:
        runtime.free()
    source = null
    mesh = null
    push_error("GROUNDCOVER_DENSITY: " + message)
    await process_frame
    quit(1)

func _run() -> void:
    var mesh := BoxMesh.new()
    mesh.size = Vector3(0.1, 0.4, 0.1)
    var source := MultiMesh.new()
    source.transform_format = MultiMesh.TRANSFORM_3D
    source.use_colors = true
    source.use_custom_data = true
    source.mesh = mesh
    source.instance_count = 2
    source.set_instance_transform(0, Transform3D(Basis.IDENTITY, Vector3(1.0, 2.0, 3.0)))
    source.set_instance_transform(1, Transform3D(Basis.IDENTITY, Vector3(-2.0, 4.0, 5.0)))
    source.set_instance_color(0, Color(0.8, 0.9, 0.7, 1.0))
    source.set_instance_color(1, Color(0.7, 0.8, 0.6, 1.0))
    source.set_instance_custom_data(0, Color(0.17, 0.41, 0.23, 1.0))
    source.set_instance_custom_data(1, Color(0.63, 0.29, 0.72, 1.0))

    var before_a := source.get_instance_transform(0).origin
    var before_b := source.get_instance_transform(1).origin
    print("YARDMAN_GROUNDCOVER_BEFORE a=%s b=%s" % [str(before_a), str(before_b)])

    var cell := MultiMeshInstance3D.new()
    cell.name = "Plants_0_0_broadleaf_Grass"
    cell.multimesh = source
    var runtime := Runtime.new()
    if not runtime.call("_densify_grass_cell", cell):
        await _cleanup_and_fail("valid grass cell was not densified", cell, runtime, mesh, source)
        return
    if cell.multimesh.instance_count != 8:
        await _cleanup_and_fail("expected 8 tufts, got %d" % cell.multimesh.instance_count, cell, runtime, mesh, source)
        return
    if cell.multimesh.mesh != mesh:
        await _cleanup_and_fail("densification changed the shared mesh", cell, runtime, mesh, source)
        return
    if not bool(cell.get_meta("groundcover_dense", false)):
        await _cleanup_and_fail("dense metadata missing", cell, runtime, mesh, source)
        return
    if int(cell.get_meta("groundcover_source_anchors", 0)) != 2 or int(cell.get_meta("groundcover_tufts_per_anchor", 0)) != 4:
        await _cleanup_and_fail("groundcover metadata contract changed", cell, runtime, mesh, source)
        return
    if runtime.call("_densify_grass_cell", cell):
        await _cleanup_and_fail("cell densified twice", cell, runtime, mesh, source)
        return
    var original_a := cell.multimesh.get_instance_transform(0).origin
    var original_b := cell.multimesh.get_instance_transform(4).origin
    print("YARDMAN_GROUNDCOVER_AFTER a=%s b=%s" % [str(original_a), str(original_b)])
    if original_a.distance_to(before_a) > 0.0001 or original_b.distance_to(before_b) > 0.0001:
        await _cleanup_and_fail("original anchor transforms moved; before_a=%s after_a=%s before_b=%s after_b=%s" % [str(before_a), str(original_a), str(before_b), str(original_b)], cell, runtime, mesh, source)
        return
    for index in range(8):
        var pose := cell.multimesh.get_instance_transform(index)
        var expected_y := before_a.y if index < 4 else before_b.y
        if absf(pose.origin.y - expected_y) > 0.0001:
            await _cleanup_and_fail("satellite changed terrain height at index=%d expected=%.6f actual=%.6f" % [index, expected_y, pose.origin.y], cell, runtime, mesh, source)
            return
    print("YARDMAN_GROUNDCOVER_DENSITY_PASS anchors=2 tufts=8 factor=4 multimesh_batches_added=0 shadows_added=0")
    cell.multimesh = null
    cell.free()
    runtime.free()
    source = null
    mesh = null
    for _frame in range(3):
        await process_frame
    quit(0)
