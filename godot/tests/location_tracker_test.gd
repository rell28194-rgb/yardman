extends SceneTree

const Tracker = preload("res://scripts/location_tracker.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("LOCATION_TRACKER_TEST: " + message)

func _run() -> void:
    var tracker := Tracker.new()
    var outer := [[0.0, 0.0], [100.0, 0.0], [100.0, 100.0], [0.0, 100.0], [0.0, 0.0]]
    var hole := [[40.0, 40.0], [60.0, 40.0], [60.0, 60.0], [40.0, 60.0], [40.0, 40.0]]
    _check(Tracker.point_in_ring(Vector2(10.0, 10.0), outer), "point-in-ring rejected an interior point")
    _check(Tracker.point_in_ring(Vector2(0.0, 50.0), outer), "parish boundary edge should count as contained")
    _check(not Tracker.point_in_ring(Vector2(110.0, 50.0), outer), "point-in-ring accepted an exterior point")
    _check(Tracker.polygon_contains(Vector2(20.0, 20.0), [outer, hole]), "polygon rejected valid parish interior")
    _check(not Tracker.polygon_contains(Vector2(50.0, 50.0), [outer, hole]), "polygon ignored an interior hole")

    tracker._parishes = {
        "West": [{"bounds": [0.0, 0.0, 100.0, 100.0], "rings": [outer]}],
        "East": [{"bounds": [100.0, 0.0, 200.0, 100.0], "rings": [[[100.0, 0.0], [200.0, 0.0], [200.0, 100.0], [100.0, 100.0], [100.0, 0.0]]]}],
    }
    _check(tracker._parish_at(25.0, 50.0) == "West", "runtime parish lookup did not use polygon containment")
    _check(tracker._parish_at(175.0, 50.0) == "East", "runtime parish lookup selected wrong polygon")
    _check(tracker._parish_at(100.0, 50.0).is_empty(), "shared administrative boundary should remain explicit ambiguity")
    _check(tracker._parish_at(NAN, 50.0).is_empty(), "invalid parish query must fail closed")

    tracker._tiles = {"0:0": [
        {"name": "West Town", "kind": "town", "x": 30.0, "z": 30.0, "parish": "West"},
        {"name": "East Town", "kind": "town", "x": 31.0, "z": 30.0, "parish": "East"},
    ]}
    tracker._tile_size = 4096.0
    var place := tracker._resolve_place(30.5, 30.0, "West")
    _check(str(place.settlement.get("name", "")) == "West Town", "cross-border settlement overrode containing parish")
    _check(tracker._compose_label(place, "West") == "West Town · West", "place/parish label composition changed")

    tracker.free()
    print("YARDMAN_LOCATION_TRACKER_TEST %s polygon=1 holes=1 boundary_ambiguity=1 parish_filter=1" % ["PASS" if failures == 0 else "FAIL"])
    quit(0 if failures == 0 else 1)
