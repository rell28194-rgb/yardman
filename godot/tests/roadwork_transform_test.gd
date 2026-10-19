extends SceneTree

const RoadworkScript = preload("res://scripts/roadwork_layer.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("ROADWORK_TRANSFORM_TEST: " + message)

func _run() -> void:
    _check(RoadworkScript.cone_pose_is_valid(12.0, -3.0, 418.5, 0.7), "finite cone pose was rejected")
    _check(not RoadworkScript.cone_pose_is_valid(12.0, -3.0, NAN, 0.7), "NAN terrain height was accepted")
    _check(not RoadworkScript.cone_pose_is_valid(12.0, -3.0, INF, 0.7), "infinite terrain height was accepted")
    _check(not RoadworkScript.cone_pose_is_valid(NAN, -3.0, 418.5, 0.7), "NAN local X was accepted")
    _check(not RoadworkScript.cone_pose_is_valid(12.0, INF, 418.5, 0.7), "infinite local Z was accepted")
    _check(not RoadworkScript.cone_pose_is_valid(12.0, -3.0, 418.5, NAN), "NAN yaw was accepted")
    if failures == 0:
        print("YARDMAN_ROADWORK_TRANSFORM_TEST PASS finite_contract=1")
    quit(0 if failures == 0 else 1)
