extends SceneTree

const Guidance = preload("res://scripts/job_guidance_runtime.gd")
var failures := 0

func _init() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("JOB_GUIDANCE_TEST: " + message)

func _run() -> void:
    var ahead := Guidance.guidance_state(Vector2.ZERO, Vector2(0.0, -100.0), 0.0)
    var left := Guidance.guidance_state(Vector2.ZERO, Vector2(-100.0, 0.0), 0.0)
    var right := Guidance.guidance_state(Vector2.ZERO, Vector2(100.0, 0.0), 0.0)
    var behind := Guidance.guidance_state(Vector2.ZERO, Vector2(0.0, 100.0), 0.0)
    var arrived := Guidance.guidance_state(Vector2.ZERO, Vector2.ZERO, 0.0)

    _check(str(ahead.turn) == "AHEAD", "north-facing forward destination was not AHEAD")
    _check(str(left.turn) == "LEFT", "west destination was not LEFT from north-facing camera")
    _check(str(right.turn) == "RIGHT", "east destination was not RIGHT from north-facing camera")
    _check(str(behind.turn) == "BEHIND", "south destination was not BEHIND from north-facing camera")
    _check(str(arrived.turn) == "ARRIVED" and float(arrived.distance_m) == 0.0, "coincident destination did not report ARRIVED")
    _check(absf(float(ahead.distance_m) - 100.0) < 0.001, "guidance distance changed canonical metres")
    _check(float(left.bearing_delta_deg) > 0.0 and float(right.bearing_delta_deg) < 0.0, "left/right bearing sign convention is reversed")

    var rotated := Guidance.guidance_state(Vector2.ZERO, Vector2(-100.0, 0.0), PI * 0.5)
    _check(str(rotated.turn) == "AHEAD", "camera-relative guidance ignored camera yaw")

    if failures == 0:
        print("YARDMAN_JOB_GUIDANCE_TEST PASS cardinal=4 arrived=1 metres=1 sign=1 camera_relative=1")
        quit()
    else:
        print("YARDMAN_JOB_GUIDANCE_TEST FAIL failures=%d" % failures)
        quit(1)
