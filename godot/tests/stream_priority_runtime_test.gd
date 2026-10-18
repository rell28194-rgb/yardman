extends SceneTree

const PriorityRuntime = preload("res://scripts/stream_priority_runtime.gd")
var failures := 0

class FakeCoordinates:
    extends RefCounted
    func local_to_world(local: Vector3) -> PackedFloat64Array:
        return PackedFloat64Array([local.x, local.y, local.z])

class FakeStreamer:
    extends Node
    var target: Node3D
    var coordinates = FakeCoordinates.new()
    var tile_size := 400.0
    var cell_size := 100.0
    var _queue: Array[String] = []

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("STREAM_PRIORITY_RUNTIME_TEST: " + message)

func _sorted(values: Array[String]) -> Array[String]:
    var copy: Array[String] = values.duplicate()
    copy.sort()
    return copy

func _run() -> void:
    var target := CharacterBody3D.new()
    target.position = Vector3(200.0, 0.0, 200.0)
    root.add_child(target)

    var roads := FakeStreamer.new()
    roads.target = target
    roads._queue = ["0:1", "-1:0", "1:0", "0:-1"]
    root.add_child(roads)
    var road_members := _sorted(roads._queue)

    target.velocity = Vector3(30.0, 0.0, 0.0)
    _check(PriorityRuntime.reprioritize_streamer(roads, "roads"), "road queue was not accepted")
    _check(roads._queue[0] == "1:0", "eastbound road queue did not prioritize east")
    _check(_sorted(roads._queue) == road_members, "road priority changed queue membership")

    target.velocity = Vector3(0.0, 0.0, -30.0)
    _check(PriorityRuntime.reprioritize_streamer(roads, "terrain"), "terrain-compatible queue was not accepted")
    _check(roads._queue[0] == "0:-1", "direction reversal did not reprioritize road/terrain queue")
    _check(_sorted(roads._queue) == road_members, "terrain priority changed queue membership")

    # Stationary asymmetric position detects accidental X/Z coordinate swaps.
    roads._queue = ["0:1", "1:0"]
    target.position = Vector3(395.0, 0.0, 40.0)
    target.velocity = Vector3.ZERO
    _check(PriorityRuntime.reprioritize_streamer(roads, "roads"), "asymmetric road queue was not accepted")
    _check(roads._queue[0] == "1:0", "runtime swapped world X/Z while scoring")

    roads._queue = ["-1:0", "0:0"]
    target.position = Vector3(10.0, 0.0, 200.0)
    target.velocity = Vector3(-30.0, 0.0, 0.0)
    _check(PriorityRuntime.reprioritize_streamer(roads, "roads"), "occupied-cell queue was not accepted")
    _check(roads._queue[0] == "0:0", "prediction outranked the target's occupied tile")

    var buildings := FakeStreamer.new()
    buildings.target = target
    buildings._queue = ["0:1", "-1:0", "1:0", "0:-1"]
    root.add_child(buildings)
    var building_members := _sorted(buildings._queue)
    target.position = Vector3(50.0, 0.0, 50.0)
    target.velocity = Vector3(0.0, 0.0, 30.0)
    _check(PriorityRuntime.reprioritize_streamer(buildings, "buildings"), "building queue was not accepted")
    _check(buildings._queue[0] == "0:1", "building queue did not use cell-size predictive priority")
    _check(_sorted(buildings._queue) == building_members, "building priority changed queue membership")

    # tile_size deliberately differs from cell_size. The occupied building cell
    # must be resolved with the 100 m cell size, not the 400 m road tile size.
    buildings._queue = ["0:0", "1:0"]
    target.position = Vector3(150.0, 0.0, 50.0)
    target.velocity = Vector3(30.0, 0.0, 0.0)
    _check(PriorityRuntime.reprioritize_streamer(buildings, "buildings"), "building size-disambiguation queue was not accepted")
    _check(buildings._queue[0] == "1:0", "building queue used road tile size instead of building cell size")

    buildings._queue = ["1:0"]
    _check(not PriorityRuntime.reprioritize_streamer(buildings, "buildings"),
        "single-item queue performed unnecessary sort")
    _check(not PriorityRuntime.reprioritize_streamer(null, "roads"), "null streamer was accepted")

    print("YARDMAN_STREAM_PRIORITY_RUNTIME_TEST %s road=1 terrain=1 buildings=1 occupied_first=1 direction_change=1 coordinate_axes=1 cell_size=1 membership_stable=1" %
        ("PASS" if failures == 0 else "FAIL"))
    roads.queue_free()
    buildings.queue_free()
    target.queue_free()
    quit(0 if failures == 0 else 1)
