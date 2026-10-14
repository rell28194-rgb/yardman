extends SceneTree

const BrakeLights = preload("res://scripts/traffic_brake_light_runtime.gd")
var failures := 0

func _init() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("TRAFFIC_BRAKE_LIGHT_TEST: " + message)

func _run() -> void:
    _check(not BrakeLights.brake_active(10.0, 10.0), "steady cruise incorrectly lit brake lamps")
    _check(not BrakeLights.brake_active(10.0, 9.90), "tiny speed variation incorrectly lit brake lamps")
    _check(BrakeLights.brake_active(10.0, 9.6), "meaningful deceleration did not light brake lamps")
    _check(BrakeLights.brake_active(1.2, 0.6), "stopped traffic did not hold brake lamps")
    _check(BrakeLights.brake_active(0.0, 0.0), "stationary traffic lost brake indication")
    _check(BrakeLights.emission_energy(true) > BrakeLights.emission_energy(false), "brake emission is not brighter than running lamps")
    _check(is_equal_approx(BrakeLights.emission_energy(false), BrakeLights.RUNNING_ENERGY), "running-light energy changed from vehicle baseline")

    if failures == 0:
        print("YARDMAN_TRAFFIC_BRAKE_LIGHT_TEST PASS cruise=2 decel=1 stop=2 emission=2")
        quit()
    else:
        print("YARDMAN_TRAFFIC_BRAKE_LIGHT_TEST FAIL failures=%d" % failures)
        quit(1)
