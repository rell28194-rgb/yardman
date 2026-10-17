extends SceneTree

const RuntimeContract = preload("res://scripts/vehicle_runtime_contract.gd")

var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("VEHICLE_RUNTIME_CONTRACT_TEST: " + message)

func _run() -> void:
    var vehicle := CharacterBody3D.new()
    vehicle.name = "IsolatedVehicle"
    root.add_child(vehicle)
    var visual := Node3D.new()
    visual.name = "VisualRig"
    vehicle.add_child(visual)

    var bounds := AABB(Vector3(-0.9, 0.0, -2.4), Vector3(1.8, 1.45, 4.8))
    var first := RuntimeContract.ensure_hooks(vehicle, bounds)
    _check(first.size() == RuntimeContract.REQUIRED_HOOKS.size(), "ensure_hooks did not return every required hook")
    var first_audit := RuntimeContract.audit(vehicle)
    _check(bool(first_audit.ready), "fresh vehicle contract is not ready: %s" % str(first_audit))
    _check(int(first_audit.visual_rig_count) == 1, "fresh vehicle does not have exactly one VisualRig")

    RuntimeContract.ensure_hooks(vehicle, bounds)
    var second_audit := RuntimeContract.audit(vehicle)
    _check(bool(second_audit.ready), "reapplying hooks regressed the contract: %s" % str(second_audit))
    for hook_name in RuntimeContract.REQUIRED_HOOKS:
        _check(int(second_audit.hook_counts.get(hook_name, 0)) == 1, "reapplying hooks duplicated %s" % hook_name)

    var duplicate_camera := Marker3D.new()
    duplicate_camera.name = "CameraMount"
    duplicate_camera.set_meta(RuntimeContract.HOOK_ROLE_META, "CameraMount")
    vehicle.add_child(duplicate_camera)
    var bad_audit := RuntimeContract.audit(vehicle)
    _check(not bool(bad_audit.ready), "duplicate CameraMount was accepted")
    _check("CameraMount" in bad_audit.duplicate_hooks, "duplicate CameraMount was not identified")
    duplicate_camera.free()

    var second_visual := Node3D.new()
    second_visual.name = "VisualRig"
    second_visual.set_meta(RuntimeContract.VISUAL_ROLE_META, true)
    vehicle.add_child(second_visual)
    bad_audit = RuntimeContract.audit(vehicle)
    _check(not bool(bad_audit.ready), "duplicate VisualRig was accepted")
    _check(int(bad_audit.visual_rig_count) == 2, "duplicate VisualRig count is incorrect")
    second_visual.free()

    var clean_audit := RuntimeContract.audit(vehicle)
    _check(bool(clean_audit.ready), "contract did not recover after duplicate nodes were removed: %s" % str(clean_audit))

    var complete_evidence := {
        "forward": true, "reverse": true, "steering": true, "braking": true,
        "park_exit_reenter": true, "reset_despawn": true,
        "selector_safe": true, "collider_rig_aligned": true,
        "identity_verified": true, "beta1_provenance": true, "beta2_provenance": true,
        "crown_non_regression": true,
    }
    var accepted := RuntimeContract.grade(vehicle, complete_evidence)
    _check(bool(accepted.accepted), "complete evidence was rejected: %s" % str(accepted))
    _check(int(accepted.score) == 100, "complete evidence did not score 100")
    _check(str(accepted.grade) == "A", "complete evidence did not grade A")

    var incomplete := complete_evidence.duplicate(true)
    incomplete["braking"] = false
    var rejected := RuntimeContract.grade(vehicle, incomplete)
    _check(not bool(rejected.accepted), "missing braking evidence was accepted")
    _check("braking" in rejected.failures, "missing braking evidence was not reported")

    incomplete = complete_evidence.duplicate(true)
    incomplete["beta2_provenance"] = false
    rejected = RuntimeContract.grade(vehicle, incomplete)
    _check(not bool(rejected.accepted), "single-source provenance was accepted")
    _check("dual_source_provenance" in rejected.failures, "missing Beta2 provenance was not reported")

    incomplete = complete_evidence.duplicate(true)
    incomplete["crown_non_regression"] = false
    rejected = RuntimeContract.grade(vehicle, incomplete)
    _check(not bool(rejected.accepted), "Crown regression was accepted")
    _check("crown_non_regression" in rejected.failures, "Crown regression was not reported")

    print("YARDMAN_VEHICLE_RUNTIME_CONTRACT_TEST %s hooks=%d score=%d grade=%s" % ["PASS" if failures == 0 else "FAIL", RuntimeContract.REQUIRED_HOOKS.size(), int(accepted.score), str(accepted.grade)])
    vehicle.free()
    quit(0 if failures == 0 else 1)
