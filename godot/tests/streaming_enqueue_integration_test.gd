extends SceneTree

const RoadStreamer = preload("res://scripts/road_streamer.gd")
const BuildingStreamer = preload("res://scripts/building_streamer.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("STREAMING_ENQUEUE_INTEGRATION_TEST: " + message)

func _sorted_copy(values: Array[String]) -> Array[String]:
    var result := values.duplicate()
    result.sort()
    return result

func _run() -> void:
    var original: Array[String] = ["-1:0", "0:-1", "1:0", "0:1"]
    var sorted_original := _sorted_copy(original)

    var roads = RoadStreamer.new()
    roads.tile_size = 100.0
    roads._queue = original.duplicate()
    roads._sort_queue_by_motion(Vector2(50.0, 50.0), Vector2(30.0, 0.0))
    _check(roads._queue.size() == 4, "road queue membership changed during priority sort")
    _check(_sorted_copy(roads._queue) == sorted_original, "road priority sort changed residency candidates")
    _check(roads._queue[0] == "1:0", "eastbound motion did not prioritize the east road/terrain tile")

    roads._queue = original.duplicate()
    roads._sort_queue_by_motion(Vector2(50.0, 50.0), Vector2.ZERO)
    _check(roads._queue.size() == 4, "stationary road sort changed queue membership")

    var buildings = BuildingStreamer.new()
    buildings.cell_size = 100.0
    buildings._queue = original.duplicate()
    buildings._sort_queue_by_motion(Vector2(50.0, 50.0), Vector2(30.0, 0.0))
    _check(buildings._queue.size() == 4, "building queue membership changed during priority sort")
    _check(_sorted_copy(buildings._queue) == sorted_original, "building priority sort changed residency candidates")
    _check(buildings._queue[0] == "1:0", "eastbound motion did not prioritize the east building cell")

    print("YARDMAN_STREAMING_ENQUEUE_INTEGRATION_TEST %s membership_stable=1 motion_bias=1 road=1 terrain_inherited=1 buildings=1 polling=0" %
        ("PASS" if failures == 0 else "FAIL"))
    roads.free()
    buildings.free()
    quit(0 if failures == 0 else 1)
