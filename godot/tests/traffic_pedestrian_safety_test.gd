extends SceneTree

const Safety = preload("res://scripts/traffic_pedestrian_safety_runtime.gd")
var failures := 0

func _init() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("TRAFFIC_PEDESTRIAN_SAFETY_TEST: " + message)

func _run() -> void:
    var travel := Vector2(0.0, -1.0)
    var normal_speed := 12.0

    var clear := {"clear": {"position": Vector2(8.0, -12.0)}}
    _check(is_equal_approx(Safety.pedestrian_speed_cap(Vector2.ZERO, travel, clear, normal_speed), normal_speed), "roadside pedestrian incorrectly slowed traffic")

    var behind := {"behind": {"position": Vector2(0.0, 5.0)}}
    _check(is_equal_approx(Safety.pedestrian_speed_cap(Vector2.ZERO, travel, behind, normal_speed), normal_speed), "pedestrian behind vehicle incorrectly slowed traffic")

    var far := {"far": {"position": Vector2(0.0, -40.0)}}
    _check(is_equal_approx(Safety.pedestrian_speed_cap(Vector2.ZERO, travel, far, normal_speed), normal_speed), "pedestrian outside look-ahead range slowed traffic")

    var slow := {"slow": {"position": Vector2(1.2, -16.0)}}
    var slow_cap := Safety.pedestrian_speed_cap(Vector2.ZERO, travel, slow, normal_speed)
    _check(slow_cap > 0.0 and slow_cap < normal_speed, "pedestrian in approach corridor did not produce bounded slowdown")

    var stop := {"stop": {"position": Vector2(0.5, -6.0)}}
    _check(Safety.pedestrian_speed_cap(Vector2.ZERO, travel, stop, normal_speed) == 0.0, "close pedestrian hazard did not stop traffic")

    var mixed := {
        "roadside": {"position": Vector2(7.0, -5.0)},
        "hazard": {"position": Vector2(0.4, -7.0)},
        "behind": {"position": Vector2(0.0, 3.0)},
    }
    _check(Safety.pedestrian_speed_cap(Vector2.ZERO, travel, mixed, normal_speed) == 0.0, "nearest in-corridor pedestrian was not prioritized")

    _check(is_equal_approx(Safety.pedestrian_speed_cap(Vector2.ZERO, Vector2.ZERO, stop, normal_speed), normal_speed), "invalid vehicle travel vector changed speed")

    if failures == 0:
        print("YARDMAN_TRAFFIC_PEDESTRIAN_SAFETY_TEST PASS roadside_filter=1 behind_filter=1 range=1 slowdown=1 stop=1 nearest=1 invalid=1")
        quit()
    else:
        print("YARDMAN_TRAFFIC_PEDESTRIAN_SAFETY_TEST FAIL failures=%d" % failures)
        quit(1)
