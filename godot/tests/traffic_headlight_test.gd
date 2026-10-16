extends SceneTree

const TrafficLights = preload("res://scripts/traffic_headlight_runtime.gd")
var failures := 0

func _init() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("TRAFFIC_HEADLIGHT_TEST: " + message)

func _run() -> void:
    var balanced := TrafficLights.budget_for("Balanced", 0, "mobile")
    var hot := TrafficLights.budget_for("Balanced", 5, "mobile")
    var ultra_gles := TrafficLights.budget_for("Ultra", 0, "gl_compatibility")
    _check(int(hot.vehicles) <= int(balanced.vehicles), "thermal stage did not reduce traffic light pool")
    _check(int(ultra_gles.vehicles) <= 2, "GLES traffic light pool exceeded cap")
    _check(int(hot.vehicles) >= 1, "thermal policy removed all near traffic lighting")

    var candidates: Array = [
        {"id": "far", "position": Vector3(20, 0, 0)},
        {"id": "near-b", "position": Vector3(3, 0, 0)},
        {"id": "near-a", "position": Vector3(-3, 0, 0)},
        {"id": "mid", "position": Vector3(9, 0, 0)},
    ]
    var selected := TrafficLights.select_nearest(candidates, Vector3.ZERO, 2)
    _check(selected.size() == 2, "nearest traffic selection returned wrong count")
    _check(str(selected[0].id) == "near-a" and str(selected[1].id) == "near-b", "traffic light selection is not deterministic at equal distance")

    var first := SpotLight3D.new()
    var second := SpotLight3D.new()
    var pool: Array = [first, second]
    var count := TrafficLights.apply_selected_lights(selected, pool, 1.0, balanced)
    _check(count == 2 and first.visible and second.visible, "night traffic pool did not enable selected lights")
    _check(first.light_energy > 0.0 and first.spot_range > 20.0, "traffic beam budget was not applied")
    count = TrafficLights.apply_selected_lights(selected, pool, 0.0, balanced)
    _check(count == 0 and not first.visible and not second.visible, "daytime traffic lights stayed active")
    first.free()
    second.free()

    if failures == 0:
        print("YARDMAN_TRAFFIC_HEADLIGHT_TEST PASS selection=1 renderer_budget=1 thermal=1 pool=1")
        quit()
    else:
        print("YARDMAN_TRAFFIC_HEADLIGHT_TEST FAIL failures=%d" % failures)
        quit(1)
