extends SceneTree

const Contract = preload("res://scripts/gpu_indirect_contract.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("GPU_INDIRECT_CONTRACT_TEST: " + message)

func _two_surface_mesh() -> ArrayMesh:
    var mesh := ArrayMesh.new()
    for offset in [0.0, 2.0]:
        var arrays: Array = []
        arrays.resize(Mesh.ARRAY_MAX)
        arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
            Vector3(-0.5 + offset, -0.5, 0.0),
            Vector3(0.5 + offset, -0.5, 0.0),
            Vector3(offset, 0.5, 0.0),
        ])
        arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
        mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    return mesh

func _run() -> void:
    var one_surface := BoxMesh.new()
    var valid := Contract.validate(
        one_surface, RenderingServer.MULTIMESH_TRANSFORM_3D, false, false)
    _check(bool(valid.valid), "validated transform-only 3D single-surface layout was rejected")
    _check(not bool(valid.fallback_required), "validated layout unexpectedly requests fallback")
    _check(int(valid.transform_stride_floats) == 12, "transform stride contract changed")
    _check(int(valid.command_stride_words) == 5, "Godot indirect command stride contract changed")
    _check(int(valid.instance_count_word) == 1, "instanceCount command word changed")

    var multi_surface := Contract.validate(
        _two_surface_mesh(), RenderingServer.MULTIMESH_TRANSFORM_3D, false, false)
    _check(not bool(multi_surface.valid) and str(multi_surface.reason) == "surface_count",
        "multi-surface mesh did not fail closed")

    var colors := Contract.validate(
        one_surface, RenderingServer.MULTIMESH_TRANSFORM_3D, true, false)
    _check(not bool(colors.valid) and str(colors.reason) == "instance_colors",
        "per-instance colors did not fail closed")

    var custom_data := Contract.validate(
        one_surface, RenderingServer.MULTIMESH_TRANSFORM_3D, false, true)
    _check(not bool(custom_data.valid) and str(custom_data.reason) == "instance_custom_data",
        "per-instance custom data did not fail closed")

    var transform_2d := Contract.validate(
        one_surface, RenderingServer.MULTIMESH_TRANSFORM_2D, false, false)
    _check(not bool(transform_2d.valid) and str(transform_2d.reason) == "transform_format",
        "2D MultiMesh transform layout did not fail closed")

    var missing_mesh := Contract.validate(
        null, RenderingServer.MULTIMESH_TRANSFORM_3D, false, false)
    _check(not bool(missing_mesh.valid) and str(missing_mesh.reason) == "mesh",
        "null mesh did not fail closed")

    print("YARDMAN_GPU_INDIRECT_CONTRACT_TEST %s single_surface=1 transform3d=1 no_color=1 no_custom=1" %
        ("PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)
