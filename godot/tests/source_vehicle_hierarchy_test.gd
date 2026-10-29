extends SceneTree

const FleetModel = preload("res://scripts/fleet_vehicle_model.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("SOURCE_VEHICLE_HIERARCHY: " + message)

func _node(name: String, position := Vector3.ZERO, rotation := Vector3.ZERO) -> Node3D:
    var node := Node3D.new()
    node.name = name
    node.position = position
    node.rotation = rotation
    return node

func _build_source_fixture(model: Node3D) -> Dictionary:
    var imported := _node("ToyotaSupraRZ")
    model.add_child(imported)

    var wheel_specs := {
        "WheelFL": [Vector3(-0.806, 0.357, -1.267), Vector3(0.11, 0.22, 0.03)],
        "WheelFR": [Vector3(0.806, 0.357, -1.267), Vector3(0.12, -0.21, -0.02)],
        "WheelRL": [Vector3(-0.806, 0.357, 1.197), Vector3(-0.08, 0.04, 0.01)],
        "WheelRR": [Vector3(0.806, 0.357, 1.197), Vector3(-0.09, -0.03, -0.01)],
    }
    var wheels: Dictionary = {}
    for wheel_name in wheel_specs:
        var spec: Array = wheel_specs[wheel_name]
        var wheel := _node(str(wheel_name), spec[0], spec[1])
        imported.add_child(wheel)
        wheels[wheel_name] = wheel

    var engine := _node("Engine", Vector3(0.0, 0.6, -0.8))
    imported.add_child(engine)
    var pop := _node("PopExhaust", Vector3(0.0, 0.35, 1.9))
    imported.add_child(pop)
    var exhaust := _node("Exhaust", Vector3(0.0, 0.0, 0.15))
    pop.add_child(exhaust)
    var cameras := _node("Cameras")
    imported.add_child(cameras)
    var hood := _node("HoodCameraPoint", Vector3(0.0, 1.1, -0.8))
    cameras.add_child(hood)
    var colliders := _node("Colliders")
    imported.add_child(colliders)
    var glass := _node("Glass")
    imported.add_child(glass)

    model.call("_bind_wheels", imported)
    model.call("_bind_source_semantics", imported)
    model.set("shell", imported)
    model.set("_shell_rest_position", imported.position)
    model.set("_shell_rest_rotation", imported.rotation)
    return {"root": imported, "wheels": wheels}

func _test_source_binding(scene: Node3D) -> void:
    var model := FleetModel.new() as Node3D
    scene.add_child(model)
    var fixture := _build_source_fixture(model)
    var wheels: Dictionary = fixture["wheels"]

    _check(str(model.get_meta("yardman_wheel_binding_convention", "")) == "carx_source",
        "CarX source roots did not select the source wheel convention")
    _check(bool(model.get_meta("yardman_wheel_binding_complete", false)),
        "CarX source roots did not produce a complete wheel binding")
    _check((model.get("wheels") as Array).size() == 4 and (model.get("front_pivots") as Array).size() == 2,
        "CarX source roots did not bind four wheels and two steering pivots")
    _check(absf(float(model.get("wheelbase_m")) - 2.464) < 0.01,
        "source wheelbase was not measured from original WheelF*/WheelR* roots")

    for role in ["engine", "exhaust", "pop_exhaust", "camera_hood", "collision_root", "glass"]:
        _check(model.call("semantic_node", role) != null, "missing source semantic node: " + role)
    _check(int(model.get_meta("yardman_source_semantic_count", 0)) >= 6,
        "source semantic binding count is unexpectedly low")

    var fl := wheels["WheelFL"] as Node3D
    var rl := wheels["WheelRL"] as Node3D
    var fl_rest := fl.rotation
    var rl_rest := rl.rotation
    model.call("update_motion", 0.1, 12.0, 0.20, 0.0, false, true, 0.0, 0.0)
    _check(absf(fl.rotation.x - fl_rest.x) > 0.01, "source front wheel did not spin")
    _check(absf(fl.rotation.y - (fl_rest.y + 0.20)) < 0.0001,
        "source front steering did not preserve the authored rest rotation")
    _check(absf(rl.rotation.y - rl_rest.y) < 0.0001,
        "rear source wheel received front steering")

    model.call("update_motion", 0.1, 12.0, 0.20, 0.0, false, true, 0.0, 0.0)
    _check(absf(fl.rotation.y - (fl_rest.y + 0.20)) < 0.0001,
        "source steering accumulated instead of remaining relative to the source rest pose")

func _test_legacy_binding(scene: Node3D) -> void:
    var model := FleetModel.new() as Node3D
    scene.add_child(model)
    var imported := _node("LegacyFleetFixture")
    model.add_child(imported)
    var roots := [
        ["FrontWheelLeft", Vector3(-0.8, 0.35, -1.2)],
        ["FrontWheelRight", Vector3(0.8, 0.35, -1.2)],
        ["RearWheelLeft", Vector3(-0.8, 0.35, 1.2)],
        ["RearWheelRight", Vector3(0.8, 0.35, 1.2)],
    ]
    for spec in roots:
        var pivot := _node(str(spec[0]), spec[1])
        imported.add_child(pivot)
        pivot.add_child(_node(str(spec[0]) + "Spin"))
    model.call("_bind_wheels", imported)
    _check(str(model.get_meta("yardman_wheel_binding_convention", "")) == "yardman_generated",
        "legacy Fleet64 wheel convention regressed")
    _check((model.get("wheels") as Array).size() == 4 and (model.get("front_pivots") as Array).size() == 2,
        "legacy Fleet64 wheel binding regressed")

func _run() -> void:
    var scene := Node3D.new()
    root.add_child(scene)
    _test_source_binding(scene)
    _test_legacy_binding(scene)
    if failures == 0:
        print("YARDMAN_SOURCE_VEHICLE_HIERARCHY_PASS source=carx_source legacy=yardman_generated semantics=1 rest_pose=1")
        quit(0)
        return
    print("YARDMAN_SOURCE_VEHICLE_HIERARCHY_FAIL count=%d" % failures)
    quit(1)
