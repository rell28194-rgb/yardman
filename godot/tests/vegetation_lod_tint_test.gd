extends SceneTree

const Visuals = preload("res://scripts/world_visuals.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("VEGETATION_LOD_TINT_TEST: " + message)

func _dummy_mesh(reference_name: String) -> ArrayMesh:
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
        Vector3(-0.5, 0.0, 0.0),
        Vector3(0.5, 0.0, 0.0),
        Vector3(0.0, 1.0, 0.0),
    ])
    arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.FORWARD, Vector3.FORWARD, Vector3.FORWARD])
    arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    mesh.set_meta("reference_asset", reference_name)
    return mesh

func _run() -> void:
    var visuals := Visuals.new()
    # Populate the same caches used by the production LOD builder. This forces
    # the reference near/far path without requiring owner-supplied GLB files in CI.
    visuals._plant_meshes["broadleaf"] = _dummy_mesh("fixture-near")
    visuals._reference_meshes["road_tree.glb:8.200"] = _dummy_mesh("fixture-far")

    var roadside := Node3D.new()
    get_root().add_child(roadside)
    var tile_origin := Vector2(-70000.0, 12000.0)
    var plants := [
        {"transform": Transform3D(Basis.IDENTITY, Vector3(24.0, 180.0, 32.0)), "seed": 12345},
        {"transform": Transform3D(Basis.IDENTITY, Vector3(44.0, 195.0, 52.0)), "seed": 54321},
    ]
    visuals._make_plant_cell(roadside, {"species": "broadleaf", "cell": Vector2i.ZERO, "plants": plants}, tile_origin)

    var near: MultiMeshInstance3D = roadside.get_node_or_null("Plants_0_0_broadleaf")
    var far: MultiMeshInstance3D = roadside.get_node_or_null("Plants_0_0_broadleaf_Distant")
    _check(near != null, "Near foliage cell was not built")
    _check(far != null, "Distant foliage LOD was not built")
    if near != null and far != null:
        _check(near.multimesh.instance_count == far.multimesh.instance_count, "Near/far instance counts differ")
        for index in range(near.multimesh.instance_count):
            var near_data := near.multimesh.get_instance_custom_data(index)
            var far_data := far.multimesh.get_instance_custom_data(index)
            _check(near_data.is_equal_approx(far_data), "LOD custom data changed at instance %d: %s -> %s" % [index, near_data, far_data])
            _check(absf(near_data.b - 0.5) > 0.01, "Fixture accidentally masks the old hard-coded dryness regression")
        _check(is_equal_approx(near.visibility_range_end, far.visibility_range_begin), "LOD visibility boundary no longer meets exactly")
        _check(bool(far.get_meta("distant", false)), "Far foliage lost distant classification")

    roadside.queue_free()
    await process_frame
    if failures == 0:
        print("YARDMAN_VEGETATION_LOD_TINT_TEST PASS instances=2 custom_data_parity=1 boundary=1")
    quit(0 if failures == 0 else 1)
