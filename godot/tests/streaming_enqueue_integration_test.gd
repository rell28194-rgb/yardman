extends SceneTree

const RoadStreamer = preload("res://scripts/road_streamer.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("STREAMING_ENQUEUE_INTEGRATION_TEST: " + message)

func _run() -> void:
    var roads = RoadStreamer.new()
    roads.tile_size = 100.0
    roads._queue = ["-1:0", "0:-1", "1:0", "0:1"]
    var original := roads._queue.duplicate()
    original.sort()

    roads._sort_queue_by_motion(Vector2(50.0, 50.0), Vector2(30.0, 0.0))
    _check(roads._queue.size() == 4, "queue membership changed during priority sort")
    var after := roads._queue.duplicate()
    after.sort()
    _check(after == original, "priority sort changed residency candidates")
    _check(roads._queue[0] == "1:0", "eastbound motion did not prioritize the east tile")

    roads._queue = ["-1:0", "0:-1", "1:0", "0:1"]
    roads._sort_queue_by_motion(Vector2(50.0, 50.0), Vector2.ZERO)
    _check(roads._queue.size() == 4, "stationary sort changed queue membership")

    print("YARDMAN_STREAMING_ENQUEUE_INTEGRATION_TEST %s membership_stable=1 motion_bias=1 polling=0" %
        ("PASS" if failures == 0 else "FAIL"))
    roads.free()
    quit(0 if failures == 0 else 1)
