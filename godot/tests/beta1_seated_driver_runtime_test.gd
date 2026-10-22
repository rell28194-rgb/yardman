extends SceneTree

const DriverRuntime = preload("res://scripts/beta1_seated_driver_runtime.gd")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("BETA1_SEATED_DRIVER_RUNTIME_TEST: " + message)
    quit(1)

func _transform_close(a: Transform3D, b: Transform3D, epsilon: float = 0.0001) -> bool:
    return a.origin.distance_to(b.origin) <= epsilon \
        and a.basis.x.distance_to(b.basis.x) <= epsilon \
        and a.basis.y.distance_to(b.basis.y) <= epsilon \
        and a.basis.z.distance_to(b.basis.z) <= epsilon

func _run() -> void:
    var contract := DriverRuntime.asset_contract()
    if str(contract.get("file", "")) != "road_driver_seated.glb":
        _fail("recovered seated driver filename drifted")
        return
    var fit: Vector3 = contract.get("fit_position_m", Vector3.INF)
    if fit.distance_to(Vector3(0.91, 0.21, -0.187)) > 0.0001:
        _fail("measured RHD fit translation drifted")
        return
    if absf(float(contract.get("fit_rotation_y_rad", 99.0))) > 0.0001 \
            or absf(float(contract.get("fit_scale", 0.0)) - 1.0) > 0.0001:
        _fail("source basis/scale preservation contract drifted")
        return
    if not bool(contract.get("requires_reference_crown", false)) \
            or not bool(contract.get("visible_when_occupied", false)):
        _fail("driver lost Crown/occupancy gating")
        return
    if bool(contract.get("collision", true)) \
            or bool(contract.get("physics_mutation", true)) \
            or bool(contract.get("handling_mutation", true)) \
            or bool(contract.get("fleet_mutation", true)):
        _fail("presentation driver gained gameplay authority")
        return
    if not bool(contract.get("static_source_pose", false)) \
            or not bool(contract.get("animation_retarget_pending", false)) \
            or not bool(contract.get("android_acceptance_pending", false)) \
            or not bool(contract.get("asset_absent_fallback", false)):
        _fail("pending-acceptance/fallback contract drifted")
        return

    var ancestor := Node3D.new()
    var middle := Node3D.new()
    var shell := Node3D.new()
    root.add_child(ancestor)
    ancestor.add_child(middle)
    middle.add_child(shell)
    middle.transform = Transform3D(Basis(Vector3.UP, 0.37), Vector3(1.2, 0.4, -0.6))
    shell.transform = Transform3D(Basis(Vector3.RIGHT, -0.18), Vector3(-0.2, 0.9, 0.35))
    var expected_shell_pose := middle.transform * shell.transform
    var resolved_shell_pose := DriverRuntime.relative_pose(shell, ancestor)
    if not _transform_close(resolved_shell_pose, expected_shell_pose):
        _fail("shell-to-model relative transform is incorrect")
        return

    var source_basis := Basis(Vector3.UP, -0.21)
    var driver_local := DriverRuntime.driver_local_pose(resolved_shell_pose, source_basis)
    var model_pose := resolved_shell_pose * driver_local
    var expected_model_pose := Transform3D(source_basis, DriverRuntime.DRIVER_FIT_POSITION_M)
    if not _transform_close(model_pose, expected_model_pose):
        _fail("measured model-space driver fit was not preserved through shell hierarchy")
        return

    var runtime := DriverRuntime.new()
    runtime._controller = {"occupied": true}
    if not runtime._is_occupied():
        _fail("occupied controller did not expose seated driver")
        return
    runtime._controller = {"occupied": false}
    if runtime._is_occupied():
        _fail("unoccupied controller still exposed seated driver")
        return
    runtime._controller = null
    if runtime._is_occupied():
        _fail("missing controller exposed seated driver")
        return

    ancestor.queue_free()
    runtime.free()
    print("YARDMAN_BETA1_SEATED_DRIVER_RUNTIME_TEST PASS fit=1 hierarchy=1 basis_preserved=1 occupied_only=1 crown_only=1 physics=0 handling=0 fleet=0 collision=0 animation_pending=1 android_pending=1")
    quit(0)
