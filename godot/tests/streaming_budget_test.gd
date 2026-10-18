extends SceneTree

const StreamingBudget = preload("res://scripts/streaming_budget_runtime.gd")
const RenderRuntime = preload("res://scripts/render_runtime.gd")
const Visuals = preload("res://scripts/world_visuals.gd")
var failures := 0

class FakeRoads:
    extends Node
    signal tile_content_ready(tile: Vector2i, tile_root: Node3D, segments: Array)
    signal tile_removed(tile: Vector2i)
    var tile_size := 4096.0
    var geometry_budget_us := 0

class FakeTerrain:
    extends Node
    signal tile_ready(tile: Vector2i)
    var tile_is_ready := true
    var geometry_budget_us := 0

    func is_tile_ready(_tile: Vector2i) -> bool:
        return tile_is_ready

    func height_at(_x: float, _z: float) -> float:
        return 31.0

class FakeBuildings:
    extends Node
    var geometry_budget_us := 0

class FakeScene:
    extends Node
    var roads
    var terrain
    var buildings
    var visuals
    var immediate_road_calls := 0
    var immediate_terrain_calls := 0

    func _decorate_tile(_tile: Vector2i, _root: Node3D, _segments: Array) -> void:
        immediate_road_calls += 1

    func _decorate_ready_terrain(_tile: Vector2i) -> void:
        immediate_terrain_calls += 1

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
    _check(int(balanced.roadside_geometry_us) == 1400 and int(balanced.roadside_records_per_frame) == 24, "Balanced roadside scheduler budget changed")

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
    _check(int(critical.roadside_geometry_us) < int(ultra.roadside_geometry_us), "Thermal stage did not reduce roadside work time")
    _check(int(critical.roadside_records_per_frame) < int(ultra.roadside_records_per_frame), "Thermal stage did not reduce roadside work units")

    var custom := StreamingBudget.budget_for("Custom", 0, {"road_radius": 3, "terrain_radius": 2, "building_distance": 1600.0, "building_cells": 180})
    _check(int(custom.road_radius) == 3 and int(custom.terrain_radius) == 2, "Custom stream radii were ignored")
    _check(is_equal_approx(float(custom.building_distance), 1600.0) and int(custom.building_cells) == 180, "Custom building budget was ignored")

    _test_aggregate_integration_budget()
    await _test_roadside_scheduler(balanced)
    print("YARDMAN_STREAMING_BUDGET_TEST %s quality_baselines=1 thermal_ladder=1 io_budget=1 geometry_budget=1 aggregate_envelope=1 roadside_scheduler=1" % ("PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)

func _test_aggregate_integration_budget() -> void:
    var performance := RenderRuntime.stream_integration_budget_for("Performance", 0)
    var quality := RenderRuntime.stream_integration_budget_for("Quality", 0)
    var ultra := RenderRuntime.stream_integration_budget_for("Ultra", 0)
    var ultra_hot := RenderRuntime.stream_integration_budget_for("Ultra", 5)
    _check(int(performance.total_us) < int(quality.total_us) and int(quality.total_us) < int(ultra.total_us), "Quality tiers no longer scale the shared integration envelope")
    for allocation in [performance, quality, ultra, ultra_hot]:
        _check(int(allocation.assigned_us) <= int(allocation.total_us), "Streamer slices exceed their aggregate frame envelope")
        _check(int(allocation.road_us) >= 650 and int(allocation.terrain_us) >= 650 and int(allocation.building_us) >= 500, "Shared envelope starves mandatory streamer progress")
        _check(int(allocation.roadside_us) >= 700, "Shared envelope failed to reserve roadside scheduler work")
    _check(int(ultra_hot.total_us) < int(ultra.total_us), "Thermal pressure did not contract aggregate integration time")

    var runtime := RenderRuntime.new()
    root.add_child(runtime)
    var scene := FakeScene.new()
    var roads := FakeRoads.new()
    var terrain := FakeTerrain.new()
    var buildings := FakeBuildings.new()
    scene.roads = roads
    scene.terrain = terrain
    scene.buildings = buildings
    scene.add_child(roads)
    scene.add_child(terrain)
    scene.add_child(buildings)
    root.add_child(scene)
    runtime._apply_shared_streaming_budget(scene, {"quality": "Ultra", "thermal_stage": 0})
    var applied: Dictionary = scene.get_meta("yardman_stream_integration_budget", {})
    _check(int(roads.geometry_budget_us) == int(applied.road_us), "Road streamer did not receive its shared frame slice")
    _check(int(terrain.geometry_budget_us) == int(applied.terrain_us), "Terrain streamer did not receive its shared frame slice")
    _check(int(buildings.geometry_budget_us) == int(applied.building_us), "Building streamer did not receive its shared frame slice")
    _check(int(applied.assigned_us) <= int(applied.total_us), "Applied streamer budget exceeds aggregate frame envelope")
    scene.queue_free()
    runtime.queue_free()

func _test_roadside_scheduler(balanced: Dictionary) -> void:
    var runtime := StreamingBudget.new()
    root.add_child(runtime)
    runtime._last_budget = balanced.duplicate(true)
    runtime._last_budget["roadside_geometry_us"] = 1000000
    runtime._last_budget["roadside_records_per_frame"] = 4

    var scene := FakeScene.new()
    var roads := FakeRoads.new()
    var terrain := FakeTerrain.new()
    scene.roads = roads
    scene.terrain = terrain
    scene.visuals = Visuals.new()
    scene.add_child(roads)
    scene.add_child(terrain)
    root.add_child(scene)

    roads.tile_content_ready.connect(scene._decorate_tile)
    terrain.tile_ready.connect(scene._decorate_ready_terrain)
    runtime._install_roadside_scheduler(scene)
    _check(not roads.is_connected("tile_content_ready", Callable(scene, "_decorate_tile")), "Synchronous road decoration callback remained connected")
    _check(not terrain.is_connected("tile_ready", Callable(scene, "_decorate_ready_terrain")), "Synchronous terrain decoration callback remained connected")

    var segments: Array = []
    for i in range(48):
        var x := 100.0 + float(i % 12) * 70.0
        var z := 100.0 + float(i / 12) * 75.0
        segments.append([x, z, x + 45.0, z, 7.0, 40.0, 0, str(i), "edge", 30.0, 30.0])

    var tile_root := Node3D.new()
    scene.add_child(tile_root)
    roads.tile_content_ready.emit(Vector2i.ZERO, tile_root, segments)
    terrain.tile_ready.emit(Vector2i.ZERO)
    _check(scene.immediate_road_calls == 0 and scene.immediate_terrain_calls == 0, "Tile signals still executed the old same-frame decoration path")
    _check(tile_root.get_node_or_null("RoadsideProxy") == null, "Roadside vegetation was built synchronously on the tile completion frame")

    runtime._pump_roadside_jobs()
    _check(runtime._roadside_jobs.size() == 1, "Roadside scheduler ignored its per-frame work-unit cap")

    for _frame in range(512):
        if runtime._roadside_jobs.is_empty():
            break
        runtime._pump_roadside_jobs()
    _check(runtime._roadside_jobs.is_empty(), "Roadside scheduler failed to drain bounded work")
    var roadside := tile_root.get_node_or_null("RoadsideProxy")
    _check(roadside != null, "Budgeted roadside build never installed its completed proxy")
    if roadside != null:
        _check(bool(roadside.get_meta("yardman_budgeted_stream_build", false)), "Roadside proxy is missing the budgeted-build diagnostic marker")
        _check(int(roadside.get_meta("plant_count", 0)) > 0, "Budgeted roadside build placed no vegetation")

    roads.tile_removed.emit(Vector2i.ZERO)
    _check(runtime._roadside_pending.is_empty() and runtime._roadside_jobs.is_empty(), "Roadside scheduler retained unloaded tile work")
    runtime._detach_roadside_scheduler()
    scene.queue_free()
    runtime.queue_free()
    await process_frame
