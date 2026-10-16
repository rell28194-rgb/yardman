extends SceneTree

const BudgetRuntime = preload("res://scripts/vegetation_budget_runtime.gd")

var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("VEGETATION_BUDGET_TEST: " + message)

func _run() -> void:
    var roadside := Node3D.new()
    root.add_child(roadside)

    var multi := MultiMesh.new()
    multi.transform_format = MultiMesh.TRANSFORM_3D
    multi.instance_count = 10
    multi.visible_instance_count = 8
    var mesh := BoxMesh.new()
    multi.mesh = mesh

    var cell := MultiMeshInstance3D.new()
    cell.multimesh = multi
    cell.visibility_range_end = 1000.0
    roadside.add_child(cell)

    var reduced := BudgetRuntime.apply_factor(roadside, 0.5)
    _check(int(reduced.cells) == 1, "roadside cell not counted")
    _check(cell.multimesh.visible_instance_count == 4, "thermal factor did not reduce visible instances from quality baseline")
    _check(cell.visibility_range_end < 1000.0 and cell.visibility_range_end > 700.0, "thermal draw-range contraction outside intended band")

    var restored := BudgetRuntime.apply_factor(roadside, 1.0)
    _check(cell.multimesh.visible_instance_count == 8, "factor 1.0 did not restore baseline visible count")
    _check(is_equal_approx(cell.visibility_range_end, 1000.0), "factor 1.0 did not restore baseline draw range")
    _check(int(restored.visible_instances) == 8, "restored runtime statistics incorrect")

    roadside.queue_free()
    await process_frame
    print("YARDMAN_VEGETATION_BUDGET_TEST %s cells=1 baseline=8 thermal=4" % ("PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)
