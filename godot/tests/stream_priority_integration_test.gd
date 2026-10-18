extends SceneTree

const Roads = preload("res://scripts/road_streamer.gd")
const Terrain = preload("res://scripts/terrain_streamer.gd")
const TILE := 4096.0
var failures := 0

class FakeCoordinates:
    extends RefCounted
    func local_to_world(local: Vector3) -> PackedFloat64Array:
        return PackedFloat64Array([local.x, local.y, local.z])
    func tile_for(x: float, z: float) -> Vector2i:
        return Vector2i(floori(x / TILE), floori(z / TILE))

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("STREAM_PRIORITY_INTEGRATION_TEST: " + message)

func _run() -> void:
    _test_queue_membership_and_order()
    _test_same_tile_resort()
    _test_teleport_rejection()
    _test_terrain_inherits_scheduler()
    print("YARDMAN_STREAM_PRIORITY_INTEGRATION_TEST %s membership=1 same_tile=1 teleport=1 terrain_shared=1" % (
        "PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)

func _new_roads() -> Node:
    var roads = Roads.new()
    roads.tile_size = TILE
    roads.coordinates = FakeCoordinates.new()
    return roads

func _test_queue_membership_and_order() -> void:
    var roads = _new_roads()
    var original: Array[String] = ["-1:0", "1:0", "0:-1", "0:1", "1:1", "-1:-1"]
    roads._queue = original.duplicate()
    roads._sort_priority_queue(Vector2(TILE - 46.0, TILE * 0.5), Vector2(38.0, 0.0))
    _check(roads._queue[0] == "1:0", "eastbound queue did not put east tile first")
    var before := original.duplicate()
    var after: Array[String] = roads._queue.duplicate()
    before.sort()
    after.sort()
    _check(before == after, "priority sort changed queue membership")
    roads.free()

func _test_same_tile_resort() -> void:
    var roads = _new_roads()
    roads.load_radius = 1
    var target := Node3D.new()
    root.add_child(target)
    roads.target = target
    for z in range(-1, 2):
        for x in range(-1, 2):
            roads._tile_files[roads._tile_key(x, z)] = "test-only"
    var resident := Node3D.new()
    roads._loaded["0:0"] = resident
    target.position = Vector3(TILE - 90.0, 0.0, TILE * 0.5)
    roads._refresh_tiles(true)
    var wanted_before: Array = roads._wanted.keys()
    wanted_before.sort()

    # Prime a one-second eastbound motion sample without waiting on wall time.
    target.position.x += 38.0
    roads._priority_has_sample = true
    roads._priority_last_world_xz = Vector2(target.position.x - 38.0, target.position.z)
    roads._priority_last_sample_msec = Time.get_ticks_msec() - 1000
    roads._refresh_tiles(false)

    _check(not roads._queue.is_empty() and roads._queue[0] == "1:0",
        "same-tile refresh did not re-sort pending queue toward travel direction")
    var wanted_after: Array = roads._wanted.keys()
    wanted_after.sort()
    _check(wanted_before == wanted_after, "same-tile re-sort changed residency candidate set")
    _check(roads._loaded.has("0:0"), "same-tile re-sort disturbed resident current tile")
    resident.free()
    target.queue_free()
    roads.free()

func _test_teleport_rejection() -> void:
    var roads = _new_roads()
    var target := Node3D.new()
    root.add_child(target)
    roads.target = target
    target.position = Vector3(100.0, 0.0, 100.0)
    roads._priority_sample_motion(1000)
    target.position = Vector3(138.0, 0.0, 100.0)
    var ordinary: Dictionary = roads._priority_sample_motion(2000)
    _check(absf(float((ordinary.velocity_mps as Vector2).x) - 38.0) < 0.001,
        "ordinary motion sample did not preserve measured velocity")
    target.position = Vector3(20138.0, 0.0, 100.0)
    var teleported: Dictionary = roads._priority_sample_motion(3000)
    _check((teleported.velocity_mps as Vector2) == Vector2.ZERO,
        "large teleport/rebase-like displacement polluted prediction velocity")
    target.queue_free()
    roads.free()

func _test_terrain_inherits_scheduler() -> void:
    var terrain = Terrain.new()
    _check(terrain.has_method("_sort_priority_queue"),
        "terrain streamer did not inherit shared predictive queue scheduler")
    _check(terrain.has_method("_priority_sample_motion"),
        "terrain streamer did not inherit shared motion sampling")
    terrain.free()
