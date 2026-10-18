extends SceneTree

const ResponsiveRoad = preload("res://scripts/rdx_responsive_road_streamer.gd")
const ResponsiveBuildings = preload("res://scripts/rdx_responsive_building_streamer.gd")

var failures := 0

class FakeCoordinates:
    extends RefCounted
    var cell_size := 100.0

    func local_to_world(local: Vector3) -> PackedFloat64Array:
        return PackedFloat64Array([local.x, local.y, local.z])

    func tile_for(x: float, z: float) -> Vector2i:
        return Vector2i(floori(x / cell_size), floori(z / cell_size))

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("STREAMING_RESPONSIVE_PRIORITY_TEST: " + message)

func _sorted(values: Array[String]) -> Array[String]:
    var copy := values.duplicate()
    copy.sort()
    return copy

func _run() -> void:
    var original: Array[String] = ["1:0", "0:1", "-1:0", "0:-1"]
    var expected_members := _sorted(original)
    var target := CharacterBody3D.new()
    target.position = Vector3(50.0, 0.0, 50.0)
    root.add_child(target)

    var roads = ResponsiveRoad.new()
    roads.tile_size = 100.0
    roads.load_radius = 2
    roads.coordinates = FakeCoordinates.new()
    roads.target = target
    roads._tile_files = {"0:0": "test-only"}
    roads._last_tile = Vector2i.ZERO
    roads._last_radius = roads.load_radius
    roads._queue = original.duplicate()
    root.add_child(roads)

    target.velocity = Vector3(30.0, 0.0, 0.0)
    roads._refresh_tiles(false)
    _check(roads._queue[0] == "1:0", "same-tile eastbound road queue did not re-rank east")
    _check(_sorted(roads._queue) == expected_members, "road re-ranking changed queue membership")
    target.velocity = Vector3(0.0, 0.0, 30.0)
    roads._refresh_tiles(false)
    _check(roads._queue[0] == "0:1", "same-tile direction change left road/terrain queue stale")
    _check(_sorted(roads._queue) == expected_members, "road direction re-ranking changed queue membership")

    var buildings = ResponsiveBuildings.new()
    buildings.cell_size = 100.0
    buildings.manifest = {"test_only": true}
    buildings.target = target
    buildings._last_cell = Vector2i.ZERO
    buildings._queue = original.duplicate()
    root.add_child(buildings)

    target.velocity = Vector3(30.0, 0.0, 0.0)
    buildings.update_world(50.0, 50.0, false)
    _check(buildings._queue[0] == "1:0", "same-cell eastbound building queue did not re-rank east")
    _check(_sorted(buildings._queue) == expected_members, "building re-ranking changed queue membership")
    target.velocity = Vector3(0.0, 0.0, -30.0)
    buildings.update_world(50.0, 50.0, false)
    _check(buildings._queue[0] == "0:-1", "same-cell direction reversal left building queue stale")
    _check(_sorted(buildings._queue) == expected_members, "building direction re-ranking changed queue membership")

    print("YARDMAN_STREAMING_RESPONSIVE_PRIORITY_TEST %s road=1 terrain_inherited=1 buildings=1 same_cell=1 direction_change=1 membership_stable=1" %
        ("PASS" if failures == 0 else "FAIL"))
    roads.queue_free()
    buildings.queue_free()
    target.queue_free()
    quit(0 if failures == 0 else 1)
