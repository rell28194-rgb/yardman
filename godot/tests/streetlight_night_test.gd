extends SceneTree

const NightLights = preload("res://scripts/streetlight_night_runtime.gd")
var failures := 0

func _init() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("STREETLIGHT_NIGHT_TEST: " + message)

func _run() -> void:
    _check(is_equal_approx(NightLights.night_factor(0.0), 1.0), "midnight lamps should be fully active")
    _check(is_equal_approx(NightLights.night_factor(12.0), 0.0), "midday lamps should be off")
    _check(NightLights.night_factor(18.75) > NightLights.night_factor(18.25), "dusk activation must rise smoothly")
    _check(NightLights.night_factor(6.25) < NightLights.night_factor(5.50), "dawn activation must fall smoothly")

    var balanced := NightLights.budget_for("Balanced", 0, "mobile")
    var hot := NightLights.budget_for("Balanced", 5, "mobile")
    var gles := NightLights.budget_for("Ultra", 0, "gl_compatibility")
    _check(int(hot.real_lights) < int(balanced.real_lights), "thermal light budget did not degrade")
    _check(int(gles.real_lights) <= 7, "GLES light budget exceeded fallback cap")
    _check(int(hot.real_lights) >= 2, "thermal policy removed all night illumination")

    var origin := Vector3.ZERO
    var candidates: Array = [Vector3(20, 0, 0), Vector3(3, 0, 0), Vector3(10, 0, 0), Vector3(1, 0, 0)]
    var nearest := NightLights.nearest_positions(candidates, origin, 2)
    _check(nearest.size() == 2, "nearest-light selection returned wrong count")
    _check(nearest[0] == Vector3(1, 0, 0) and nearest[1] == Vector3(3, 0, 0), "nearest-light selection is not distance ordered")
    var none := NightLights.nearest_positions(candidates, origin, 0)
    _check(none.is_empty(), "zero light budget must select no positions")

    if failures == 0:
        print("YARDMAN_STREETLIGHT_NIGHT_TEST PASS clock=1 renderer_budget=1 thermal=1 nearest_pool=1")
        quit()
    else:
        print("YARDMAN_STREETLIGHT_NIGHT_TEST FAIL failures=%d" % failures)
        quit(1)
