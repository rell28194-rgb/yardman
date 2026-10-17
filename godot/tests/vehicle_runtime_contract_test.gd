extends SceneTree

const RuntimeContract = preload("res://scripts/vehicle_runtime_contract.gd")

func _init() -> void:
    var vehicle := CharacterBody3D.new()
    vehicle.name = "IsolatedVehicle"
    root.add_child(vehicle)
    var visual := Node3D.new()
    visual.name = "VisualRig"
    vehicle.add_child(visual)

    var bounds := AABB(Vector3(-0.9, 0.0, -2.4), Vector3(1.8, 1.45, 4.8))
    var first := RuntimeContract.ensure_hooks(vehicle, bounds)
    assert(first.size() == RuntimeContract.REQUIRED_HOOKS.size())
    var first_audit := RuntimeContract.audit(vehicle)
    assert(bool(first_audit.ready))
    assert(int(first_audit.visual_rig_count) == 1)

    # Re-applying the contract must update/reuse hooks, never duplicate them.
    RuntimeContract.ensure_hooks(vehicle, bounds)
    var second_audit := RuntimeContract.audit(vehicle)
    assert(bool(second_audit.ready))
    for hook_name in RuntimeContract.REQUIRED_HOOKS:
        assert(vehicle.find_children(hook_name, "Marker3D", true, false).size() == 1)

    # The contract must detect orphan/duplicate game-facing nodes before a car
    # is admitted to the map lane.
    var duplicate_camera := Marker3D.new()
    duplicate_camera.name = "CameraMount"
    vehicle.add_child(duplicate_camera)
    var bad_audit := RuntimeContract.audit(vehicle)
    assert(not bool(bad_audit.ready))
    assert("CameraMount" in bad_audit.duplicate_hooks)
    duplicate_camera.free()

    var second_visual := Node3D.new()
    second_visual.name = "VisualRig"
    vehicle.add_child(second_visual)
    bad_audit = RuntimeContract.audit(vehicle)
    assert(not bool(bad_audit.ready))
    assert(int(bad_audit.visual_rig_count) == 2)
    second_visual.free()

    var clean_audit := RuntimeContract.audit(vehicle)
    assert(bool(clean_audit.ready))
    print("YARDMAN_VEHICLE_RUNTIME_CONTRACT_TEST_PASS hooks=%d visual_rigs=%d" % [RuntimeContract.REQUIRED_HOOKS.size(), int(clean_audit.visual_rig_count)])
    vehicle.free()
    quit(0)
