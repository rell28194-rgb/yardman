extends SceneTree

const Pedestrians = preload("res://scripts/pedestrian_runtime.gd")
var failures := 0

func _init() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("PEDESTRIAN_RUNTIME_TEST: " + message)

func _run() -> void:
    var road := {"a": Vector2(0, 0), "b": Vector2(120, 0), "width_m": 8.0, "edge_id": "walk-road"}
    var left := Pedestrians.roadside_walk_pose(road, 0.5, 1, 1)
    var right := Pedestrians.roadside_walk_pose(road, 0.5, 1, -1)
    var reverse := Pedestrians.roadside_walk_pose(road, 0.5, -1, 1)
    _check(not left.is_empty() and not right.is_empty(), "roadside walking corridor generation failed")
    _check(absf(Vector2(left.position).x - 60.0) < 0.001, "walking corridor changed source road station")
    _check(absf(Vector2(left.position).y) > 4.0, "walking corridor remained inside source carriageway")
    _check(Vector2(left.position).y * Vector2(right.position).y < 0.0, "opposite roadside corridors should be on opposite sides")
    _check(Vector2(left.travel).dot(Vector2(reverse.travel)) < -0.99, "reverse pedestrian travel heading incorrect")

    _check(Pedestrians.density_for_hour(13.0) > Pedestrians.density_for_hour(3.0), "daytime pedestrian density should exceed overnight density")
    _check(Pedestrians.density_for_hour(18.0) > Pedestrians.density_for_hour(23.5), "evening activity should exceed late-night density")

    var balanced := Pedestrians.budget_for("Balanced", 0)
    var hot := Pedestrians.budget_for("Balanced", 5)
    var performance := Pedestrians.budget_for("Performance", 0)
    _check(int(hot.max_agents) < int(balanced.max_agents), "thermal pedestrian population did not degrade")
    _check(int(hot.near_visuals) <= int(balanced.near_visuals), "thermal near pedestrian budget did not degrade")
    _check(int(performance.max_agents) < int(balanced.max_agents), "Performance pedestrian budget should be smaller")
    _check(float(hot.near_radius) >= 60.0 and float(hot.medium_radius) >= 175.0, "thermal policy erased pedestrian simulation coverage")

    if failures == 0:
        print("YARDMAN_PEDESTRIAN_RUNTIME_TEST PASS road_context=2 directions=2 density_cycle=1 simulation_lod=3")
        quit()
    else:
        print("YARDMAN_PEDESTRIAN_RUNTIME_TEST FAIL failures=%d" % failures)
        quit(1)
