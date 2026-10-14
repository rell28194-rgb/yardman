extends SceneTree

const StreamingBudget = preload("res://scripts/streaming_budget_runtime.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("STREAMING_BUDGET_TEST: " + message)

func _run() -> void:
    var balanced := StreamingBudget.budget_for("Balanced", 0)
    _check(int(balanced.road_radius) == 2 and int(balanced.terrain_radius) == 1, "Balanced baseline changed canonical stream radii")
    _check(is_equal_approx(float(balanced.building_distance), 800.0) and int(balanced.building_cells) == 96, "Balanced building baseline changed")
    _check(int(balanced.io_jobs) == 2, "Cool baseline lost dual IO concurrency")

    var ultra := StreamingBudget.budget_for("Ultra", 0)
    var warm := StreamingBudget.budget_for("Ultra", 3)
    var critical := StreamingBudget.budget_for("Ultra", 5)
    _check(int(ultra.road_radius) == 3 and int(ultra.terrain_radius) == 2, "Ultra baseline no longer holds the wider resident island window")
    _check(int(warm.road_radius) == 2 and int(warm.terrain_radius) == 1, "Warm thermal stage did not contract fine stream radii")
    _check(float(warm.building_distance) < float(ultra.building_distance), "Warm stage did not reduce building residency distance")
    _check(int(warm.building_cells) < int(ultra.building_cells), "Warm stage did not reduce building cell count")
    _check(int(warm.io_jobs) == 1, "Warm stage retained competing IO jobs")
    _check(int(critical.road_radius) == 1 and int(critical.terrain_radius) == 1, "Critical stage did not reach minimum fine-cell radii")
    _check(float(critical.building_distance) >= 320.0, "Critical stage destroyed the inhabited near field")
    _check(int(critical.road_segments_per_frame) >= 128 and int(critical.building_records_per_frame) >= 8, "Critical stage starved streaming progress")
    _check(int(critical.road_geometry_us) < int(ultra.road_geometry_us), "Thermal stage did not reduce per-frame road geometry budget")

    var custom := StreamingBudget.budget_for("Custom", 0, {"road_radius": 3, "terrain_radius": 2, "building_distance": 1600.0, "building_cells": 180})
    _check(int(custom.road_radius) == 3 and int(custom.terrain_radius) == 2, "Custom stream radii were ignored")
    _check(is_equal_approx(float(custom.building_distance), 1600.0) and int(custom.building_cells) == 180, "Custom building budget was ignored")

    print("YARDMAN_STREAMING_BUDGET_TEST %s quality_baselines=1 thermal_ladder=1 io_budget=1 geometry_budget=1" % ("PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)
