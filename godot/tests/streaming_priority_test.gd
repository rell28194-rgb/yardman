extends SceneTree

const Priority = preload("res://scripts/streaming_priority.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("STREAMING_PRIORITY_TEST: " + message)

func _run() -> void:
    var size := 4096.0
    var center := Vector2(2048.0, 2048.0)
    var east := Vector2i(1, 0)
    var north := Vector2i(0, 1)
    var west := Vector2i(-1, 0)

    var east_stationary := Priority.priority_score(east, center, Vector2.ZERO, size)
    _check(is_equal_approx(east_stationary, 2048.0), "stationary footprint distance is incorrect")

    var east_moving := Priority.priority_score(east, center, Vector2(30.0, 0.0), size, 8.0)
    var north_moving := Priority.priority_score(north, center, Vector2(30.0, 0.0), size, 8.0)
    var west_moving := Priority.priority_score(west, center, Vector2(30.0, 0.0), size, 8.0)
    _check(east_moving < north_moving, "forward tile was not promoted over an equal-distance side tile")
    _check(east_moving < west_moving, "forward tile was not promoted over the tile behind motion")

    var east_westbound := Priority.priority_score(east, center, Vector2(-30.0, 0.0), size, 8.0)
    var west_westbound := Priority.priority_score(west, center, Vector2(-30.0, 0.0), size, 8.0)
    _check(west_westbound < east_westbound, "priority did not reverse when travel direction reversed")

    var near_east_edge := Vector2(4090.0, 2048.0)
    _check(is_equal_approx(Priority.cell_distance(east, near_east_edge, size), 6.0),
        "near-boundary geometry was still scored by distant cell center")
    _check(Priority.less(east, west, near_east_edge, Vector2.ZERO, size),
        "precise in-tile position did not beat coarse tile-index distance")

    var crossing_east := Priority.priority_score(east, near_east_edge, Vector2(30.0, 0.0), size, 8.0)
    var crossing_north := Priority.priority_score(north, near_east_edge, Vector2(30.0, 0.0), size, 8.0)
    _check(crossing_east < crossing_north,
        "boundary-crossing motion did not prioritize the cell entered next")

    _check(Priority.less(north, east, center, Vector2.ZERO, size),
        "stationary tie breaker is not deterministic")

    var invalid := Priority.priority_score(Vector2i.ZERO, Vector2(INF, 0.0), Vector2.ZERO, size)
    _check(is_inf(invalid), "non-finite target position was not safely rejected")

    print("YARDMAN_STREAMING_PRIORITY_TEST %s footprint_distance=1 motion_bias=1 boundary_crossing=1 reverse=1 deterministic=1" % ("PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)
