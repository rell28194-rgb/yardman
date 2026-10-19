extends SceneTree

const Roads = preload("res://scripts/road_streamer.gd")
var failures := 0

class FixtureRoads:
    extends "res://scripts/road_streamer.gd"
    func _ready() -> void:
        pass
    func _process(_delta: float) -> void:
        pass

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("ROAD_INTEGRATION_BUDGET_TEST: " + message)

# Explicit test-only synthetic road records, never production geography.
func _fixture_segment(dirt: bool) -> Array:
    return [0.0, 0.0, 10.0, 0.0, 6.0, 0, 8 if dirt else 0, "fixture-road", 0, 0.0, 0.0,
        [[0.0, 0.0, 3.0], [0.0, 0.0, -3.0], [10.0, 0.0, -3.0], [10.0, 0.0, 3.0]]]

func _stream_with_fixture(count: int) -> Node:
    var stream = FixtureRoads.new()
    root.add_child(stream)
    stream.geometry_budget_us = 1000000
    stream.max_segments_per_frame = 10000
    var segments: Array = []
    for index in range(count):
        segments.append(_fixture_segment(index % 2 == 1))
    var thread := Thread.new()
    thread.start(func() -> Dictionary: return {"segments": segments})
    while thread.is_alive():
        OS.delay_usec(100)
    stream._wanted["0:0"] = true
    stream._jobs["0:0"] = {"thread": thread, "generation": 0}
    stream._poll_jobs()
    return stream

func _run() -> void:
    _test_final_batch()
    _test_intermediate_batch()
    _test_cancel_upload()
    print("YARDMAN_ROAD_INTEGRATION_BUDGET_TEST %s final_upload=1 intermediate_upload=1 publication=1 cancellation=1" % ("PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)

func _test_final_batch() -> void:
    var stream = _stream_with_fixture(2)
    var events: Array = []
    stream.tile_ready.connect(func(tile: Vector2i): events.append(["ready", tile]))
    stream.tile_content_ready.connect(func(tile: Vector2i, _node: Node3D, segments: Array): events.append(["content", tile, segments.size()]))
    var staging: Node3D = stream._building.root
    stream._prepare_geometry()
    _check(staging.get_child_count() == 0 and stream._loaded.is_empty(), "CPU preparation performed uploads/publication")
    stream._prepare_geometry()
    _check(staging.get_child_count() == 1 and staging.get_child(0).name == "paved", "First upload did not isolate paved mesh")
    stream._prepare_geometry()
    _check(staging.get_child_count() == 2 and stream._loaded.is_empty() and events.is_empty(), "Second upload published before separate integration step")
    stream._prepare_geometry()
    _check(stream._loaded.get("0:0") == staging and stream._building.is_empty(), "Completed tile was not published")
    _check(events == [["ready", Vector2i.ZERO], ["content", Vector2i.ZERO, 2]], "Publication signals/order or original segments changed")
    _check(not stream._surface_indices["0:0"].is_empty(), "Phased upload lost road surface queries")
    for mesh_node in staging.get_children():
        _check(mesh_node.mesh.surface_get_array_len(0) == 4 and mesh_node.mesh.surface_get_array_index_len(0) == 6, "Phased upload changed road geometry")
    stream.free()

func _test_intermediate_batch() -> void:
    var stream = _stream_with_fixture(2050)
    var staging: Node3D = stream._building.root
    stream._prepare_geometry()
    _check(int(stream._building.cursor) == 2048 and staging.get_child_count() == 0, "Intermediate boundary uploaded or continued CPU work")
    stream._prepare_geometry()
    _check(staging.get_child_count() == 1 and int(stream._building.cursor) == 2048, "Intermediate paved upload continued CPU work")
    stream._prepare_geometry()
    _check(staging.get_child_count() == 2 and int(stream._building.cursor) == 2048, "Intermediate dirt upload continued CPU work")
    stream._prepare_geometry()
    _check(stream._loaded.is_empty() and int(stream._building.cursor) == 2048, "Intermediate completion published a partial tile")
    stream._prepare_geometry()
    _check(int(stream._building.cursor) == 2050 and staging.get_child_count() == 2, "Final CPU work uploaded in the same invocation")
    for step in range(3):
        stream._prepare_geometry()
    _check(stream._loaded.get("0:0") == staging and staging.get_child_count() == 4, "Intermediate/final batch meshes were lost")
    stream.free()

func _test_cancel_upload() -> void:
    var stream = _stream_with_fixture(2)
    stream._prepare_geometry()
    stream._prepare_geometry()
    var staging: Node3D = stream._building.root
    stream.free()
    _check(not is_instance_valid(staging), "Cancellation leaked a partially uploaded staging root")
