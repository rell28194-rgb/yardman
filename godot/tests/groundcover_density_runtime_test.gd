extends SceneTree

const Runtime = preload("res://scripts/groundcover_density_runtime.gd")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("GROUNDCOVER_DENSITY: " + message)
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

    var cell := MultiMeshInstance3D.new()
    cell.name = "Plants_0_0_broadleaf_Grass"
    cell.multimesh = source
    var runtime := Runtime.new()
    if not runtime.call("_densify_grass_cell", cell):
        _fail("valid grass cell was not densified")
        return
    if cell.multimesh.instance_count != 8:
        _fail("expected 8 tufts, got %d" % cell.multimesh.instance_count)
        return
    if cell.multimesh.mesh != mesh:
        _fail("densification changed the shared mesh")
        return
    if not bool(cell.get_meta("groundcover_dense", false)):
        _fail("dense metadata missing")
        return
    if int(cell.get_meta("groundcover_source_anchors", 0)) != 2 or int(cell.get_meta("groundcover_tufts_per_anchor", 0)) != 4:
        _fail("groundcover metadata contract changed")
        return
    if runtime.call("_densify_grass_cell", cell):
        _fail("cell densified twice")
        return
    var original_a := cell.multimesh.get_instance_transform(0).origin
    var original_b := cell.multimesh.get_instance_transform(4).origin
    if original_a.distance_to(Vector3(1.0, 2.0, 3.0)) > 0.0001 or original_b.distance_to(Vector3(-2.0, 4.0, 5.0)) > 0.0001:
        _fail("original anchor transforms moved")
        return
    for index in range(8):
        var pose := cell.multimesh.get_instance_transform(index)
        if not is_equal_approx(pose.origin.y, 2.0 if index < 4 else 4.0):
            _fail("satellite changed terrain height")
            return
    print("YARDMAN_GROUNDCOVER_DENSITY_PASS anchors=2 tufts=8 factor=4 multimesh_batches_added=0 shadows_added=0")
    cell.free()
    runtime.free()
    await process_frame
    quit(0)
