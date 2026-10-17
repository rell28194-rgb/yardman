extends SceneTree

const RuntimeContract = preload("res://scripts/vehicle_runtime_contract.gd")

func _initialize() -> void:
    call_deferred("_run")

func _run() -> void:
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

    RuntimeContract.ensure_hooks(vehicle, bounds)
    var second_audit := RuntimeContract.audit(vehicle)
    assert(bool(second_audit.ready))
    for hook_name in RuntimeContract.REQUIRED_HOOKS:
        assert(vehicle.find_children(hook_name, "Marker3D", true, false).size() == 1)

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

    var complete_evidence := {
        "forward": true, "reverse": true, "steering": true, "braking": true,
        "park_exit_reenter": true, "reset_despawn": true,
        "selector_safe": true, "collider_rig_aligned": true,
        "identity_verified": true, "beta1_provenance": true, "beta2_provenance": true,
        "crown_non_regression": true,
    }
    var accepted := RuntimeContract.grade(vehicle, complete_evidence)
    assert(bool(accepted.accepted))
    assert(int(accepted.score) == 100)
    assert(str(accepted.grade) == "A")

    var incomplete := complete_evidence.duplicate(true)
    incomplete["braking"] = false
    var rejected := RuntimeContract.grade(vehicle, incomplete)
    assert(not bool(rejected.accepted))
    assert("braking" in rejected.failures)

    incomplete = complete_evidence.duplicate(true)
    incomplete["beta2_provenance"] = false
    rejected = RuntimeContract.grade(vehicle, incomplete)
    assert(not bool(rejected.accepted))
    assert("dual_source_provenance" in rejected.failures)

    incomplete = complete_evidence.duplicate(true)
    incomplete["crown_non_regression"] = false
    rejected = RuntimeContract.grade(vehicle, incomplete)
    assert(not bool(rejected.accepted))
    assert("crown_non_regression" in rejected.failures)

    print("YARDMAN_VEHICLE_RUNTIME_CONTRACT_TEST_PASS hooks=%d score=%d grade=%s" % [RuntimeContract.REQUIRED_HOOKS.size(), int(accepted.score), str(accepted.grade)])
    vehicle.free()
    quit(0)
