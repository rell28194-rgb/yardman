extends SceneTree

const Idle = preload("res://scripts/pedestrian_idle_runtime.gd")
var failures := 0

func _init() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("PEDESTRIAN_IDLE_TEST: " + message)

func _run() -> void:
    var a := Idle.idle_targets(0.0)
    var b := Idle.idle_targets(PI * 0.5)
    _check(absf(float(a.left_leg_x)) < 0.01 and absf(float(a.right_leg_x)) < 0.01, "idle legs are not near neutral")
    _check(absf(float(b.left_arm_x)) < 0.08 and absf(float(b.right_arm_x)) < 0.08, "idle arm motion is too large")
    _check(absf(float(b.root_y)) < 0.02, "idle vertical breathing motion is too large")
    _check(absf(float(b.root_z)) < 0.02, "idle body sway is too large")
    _check(float(b.left_arm_x) != float(a.left_arm_x), "idle pose has no breathing variation")

    if failures == 0:
        print("YARDMAN_PEDESTRIAN_IDLE_TEST PASS neutral_legs=1 bounded_arms=1 bounded_breath=1 bounded_sway=1 variation=1")
        quit()
    else:
        print("YARDMAN_PEDESTRIAN_IDLE_TEST FAIL failures=%d" % failures)
        quit(1)
