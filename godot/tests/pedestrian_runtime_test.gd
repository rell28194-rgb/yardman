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
    var road := {"a": Vector2(0, 0), "b": Vector2(120, 0), "width_m": 8.0, "edge_id": "walk-road", "flags": 0}
    var left := Pedestrians.roadside_walk_pose(road, 0.5, 1, 1)
    var right := Pedestrians.roadside_walk_pose(road, 0.5, 1, -1)
    var reverse := Pedestrians.roadside_walk_pose(road, 0.5, -1, 1)
    _check(not left.is_empty() and not right.is_empty(), "roadside walking corridor generation failed")
    _check(absf(Vector2(left.position).x - 60.0) < 0.001, "walking corridor changed source road station")
    _check(absf(Vector2(left.position).y) > 4.0, "walking corridor remained inside source carriageway")
    _check(Vector2(left.position).y * Vector2(right.position).y < 0.0, "opposite roadside corridors should be on opposite sides")
    _check(Vector2(left.travel).dot(Vector2(reverse.travel)) < -0.99, "reverse pedestrian travel heading incorrect")
    var bridge := road.duplicate(true)
    bridge.flags = 2
    var tunnel := road.duplicate(true)
    tunnel.flags = 4
    _check(Pedestrians.roadside_walk_pose(bridge, 0.5, 1, 1).is_empty(),
        "inferred roadside corridor fabricated pedestrian support on a bridge")
    _check(Pedestrians.roadside_walk_pose(tunnel, 0.5, 1, 1).is_empty(),
        "inferred roadside corridor fabricated pedestrian support through a tunnel")

    _check(Pedestrians.density_for_hour(13.0) > Pedestrians.density_for_hour(3.0), "daytime pedestrian density should exceed overnight density")
    _check(Pedestrians.density_for_hour(18.0) > Pedestrians.density_for_hour(23.5), "evening activity should exceed late-night density")

    var dry_speed := Pedestrians.weather_walk_speed_factor(0.0, 0.0)
    var rain_speed := Pedestrians.weather_walk_speed_factor(0.70, 0.25)
    var storm_speed := Pedestrians.weather_walk_speed_factor(1.0, 1.0)
    _check(is_equal_approx(dry_speed, 1.0), "dry weather changed pedestrian walk speed")
    _check(rain_speed < dry_speed and storm_speed < rain_speed and storm_speed >= 0.72, "wet weather did not slow pedestrian movement within safe bounds")
    var dry_density := Pedestrians.weather_density_factor(0.0)
    var storm_density := Pedestrians.weather_density_factor(1.0)
    _check(storm_density < dry_density and storm_density >= 0.62, "storm did not reduce outdoor pedestrian density")
    var daytime_far := Pedestrians.statistical_population_for(18, 13.0, dry_density)
    var overnight_far := Pedestrians.statistical_population_for(18, 3.0, dry_density)
    var storm_far := Pedestrians.statistical_population_for(18, 13.0, storm_density)
    _check(daytime_far > overnight_far, "far pedestrian population ignored day/night activity")
    _check(storm_far < daytime_far and storm_far > 0, "far pedestrian activity ignored weather or collapsed entirely")

    var balanced := Pedestrians.budget_for("Balanced", 0)
    var hot := Pedestrians.budget_for("Balanced", 5)
    var performance := Pedestrians.budget_for("Performance", 0)
    _check(int(hot.max_agents) < int(balanced.max_agents), "thermal pedestrian population did not degrade")
    _check(int(hot.near_visuals) <= int(balanced.near_visuals), "thermal near pedestrian budget did not degrade")
    _check(int(performance.max_agents) < int(balanced.max_agents), "Performance pedestrian budget should be smaller")
    _check(float(hot.near_radius) >= 60.0 and float(hot.medium_radius) >= 175.0, "thermal policy erased pedestrian simulation coverage")

    if failures == 0:
        print("YARDMAN_PEDESTRIAN_RUNTIME_TEST PASS road_context=2 directions=2 structure_fail_closed=2 density_cycle=1 weather_activity=5 simulation_lod=3")
        quit()
    else:
        print("YARDMAN_PEDESTRIAN_RUNTIME_TEST FAIL failures=%d" % failures)
        quit(1)
