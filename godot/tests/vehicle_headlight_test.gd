extends SceneTree

const Headlights = preload("res://scripts/vehicle_headlight_runtime.gd")
var failures := 0

func _init() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("VEHICLE_HEADLIGHT_TEST: " + message)

func _run() -> void:
    _check(is_equal_approx(Headlights.night_factor(0.0), 1.0), "midnight headlights should be fully active")
    _check(is_equal_approx(Headlights.night_factor(12.0), 0.0), "clear midday headlights should be off")
    _check(Headlights.activation_for(12.0, 1.0) > 0.65, "heavy rain should activate daytime headlights")
    _check(Headlights.activation_for(12.0, 0.1) < 0.01, "light daytime weather should not waste headlight budget")

    var balanced := Headlights.budget_for("Balanced", 0, "mobile")
    var hot := Headlights.budget_for("Balanced", 5, "mobile")
    var gles := Headlights.budget_for("Ultra", 0, "gl_compatibility")
    _check(float(hot.range_m) < float(balanced.range_m), "thermal headlight range did not degrade")
    _check(float(gles.range_m) <= 40.0, "GLES headlight range exceeded fallback cap")
    _check(float(hot.energy) >= 2.25, "thermal policy removed usable player illumination")

    var left := SpotLight3D.new()
    var right := SpotLight3D.new()
    var lights: Array = [left, right]
    var count := Headlights.apply_lights(lights, true, 1.0, balanced)
    _check(count == 2 and left.visible and right.visible, "occupied night vehicle did not enable both headlights")
    _check(left.light_energy > 0.0 and right.light_energy > 0.0, "night headlight energy was not applied")
    count = Headlights.apply_lights(lights, true, 0.0, balanced)
    _check(count == 0 and not left.visible and not right.visible, "daytime headlights stayed active")
    count = Headlights.apply_lights(lights, false, 1.0, balanced)
    _check(count == 0 and not left.visible and not right.visible, "unoccupied vehicle kept real lights active")
    left.free()
    right.free()

    if failures == 0:
        print("YARDMAN_VEHICLE_HEADLIGHT_TEST PASS night=1 weather=1 renderer_budget=1 thermal=1 runtime=1")
        quit()
    else:
        print("YARDMAN_VEHICLE_HEADLIGHT_TEST FAIL failures=%d" % failures)
        quit(1)
