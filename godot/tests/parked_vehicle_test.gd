extends SceneTree

const Parked = preload("res://scripts/parked_vehicle_runtime.gd")
var failures := 0

func _init() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("PARKED_VEHICLE_TEST: " + message)

func _run() -> void:
    var road := {"a": Vector2(0, 0), "b": Vector2(100, 0), "width_m": 8.0, "edge_id": "road"}
    var left := Parked.parked_pose(road, 0.5, 1)
    var right := Parked.parked_pose(road, 0.5, -1)
    _check(not left.is_empty() and not right.is_empty(), "parked pose generation failed")
    _check(absf(Vector2(left.position).x - 50.0) < 0.001, "parked station moved off source segment")
    _check(Vector2(left.position).y * Vector2(right.position).y < 0.0, "parked sides should occupy opposite shoulders")
    _check(absf(Vector2(left.position).y) > 4.0, "parked car remained inside source carriageway")
    _check(float(left.shoulder_offset) > 4.0, "shoulder offset did not clear carriageway edge")

    var balanced := Parked.budget_for("Balanced", 0)
    var hot := Parked.budget_for("Balanced", 5)
    var performance := Parked.budget_for("Performance", 0)
    _check(int(hot.max_parked) < int(balanced.max_parked), "thermal parked density did not degrade")
    _check(int(hot.near_visuals) <= int(balanced.near_visuals), "thermal full-model parked budget did not degrade")
    _check(int(performance.max_parked) < int(balanced.max_parked), "Performance parked budget should be smaller")
    _check(float(hot.near_radius) >= 105.0 and float(hot.medium_radius) >= 290.0, "thermal policy erased parked-vehicle visibility coverage")

    if failures == 0:
        print("YARDMAN_PARKED_VEHICLE_TEST PASS shoulders=2 collision_tier=1 hlod_tier=1 thermal=1")
        quit()
    else:
        print("YARDMAN_PARKED_VEHICLE_TEST FAIL failures=%d" % failures)
        quit(1)
