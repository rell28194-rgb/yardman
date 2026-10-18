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
    var home := Vector2i(0, 0)
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

    # Hard invariant: predictive look-ahead must never outrank the cell the
    # target currently occupies. Before this gate, moving outward at 30 m/s
    # could make the next tile score ~2.8 while the occupied tile scored ~122.
    var near_west_edge := Vector2(10.0, 2048.0)
    var outward_velocity := Vector2(-30.0, 0.0)
    var home_score := Priority.priority_score(home, near_west_edge, outward_velocity, size)
    var west_score := Priority.priority_score(west, near_west_edge, outward_velocity, size)
    _check(is_equal_approx(home_score, 0.0), "occupied tile lost zero-priority invariant")
    _check(home_score < west_score, "future tile outranked occupied tile")
    _check(Priority.less(home, west, near_west_edge, outward_velocity, size),
        "sort comparator did not keep occupied tile first")

    var exact_boundary := Vector2(4096.0, 2048.0)
    _check(Priority.containing_cell(exact_boundary, size) == east,
        "exact boundary did not resolve to deterministic containing tile")
    _check(Priority.less(east, home, exact_boundary, Vector2(30.0, 0.0), size),
        "boundary tie did not keep deterministic occupied tile first")

    _check(Priority.less(north, east, center, Vector2.ZERO, size),
        "stationary tie breaker is not deterministic")

    var invalid := Priority.priority_score(Vector2i.ZERO, Vector2(INF, 0.0), Vector2.ZERO, size)
    _check(is_inf(invalid), "non-finite target position was not safely rejected")

    print("YARDMAN_STREAMING_PRIORITY_TEST %s footprint_distance=1 motion_bias=1 boundary_crossing=1 occupied_first=1 reverse=1 deterministic=1" % ("PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)
