extends SceneTree

const Priority = preload("res://scripts/stream_priority_policy.gd")
const TILE := 4096.0
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("STREAM_PRIORITY_POLICY_TEST: " + message)

func _run() -> void:
    _test_aabb_distance()
    _test_exact_score_contract()
    _test_stationary_symmetry()
    _test_cardinal_prediction()
    _test_diagonal_prediction()
    _test_velocity_clamp()
    _test_stable_tie_break()
    print("YARDMAN_STREAM_PRIORITY_POLICY_TEST %s aabb=1 exact_score=1 stationary=1 cardinal=1 diagonal=1 clamp=1 deterministic=1" % (
        "PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)

func _test_aabb_distance() -> void:
    _check(is_zero_approx(Priority.distance_squared_to_tile_aabb(Vector2(100.0, 200.0), Vector2i.ZERO, TILE)),
        "point inside tile should have zero AABB distance")
    _check(is_equal_approx(Priority.distance_squared_to_tile_aabb(Vector2(-10.0, 200.0), Vector2i.ZERO, TILE), 100.0),
        "10 m west of tile should be 100 square metres away")
    _check(is_equal_approx(Priority.distance_squared_to_tile_aabb(Vector2(4106.0, 200.0), Vector2i.ZERO, TILE), 100.0),
        "10 m east of tile should be 100 square metres away")
    _check(is_equal_approx(Priority.distance_squared_to_tile_aabb(Vector2(200.0, -10.0), Vector2i.ZERO, TILE), 100.0),
        "10 m north of tile should be 100 square metres away")
    _check(is_equal_approx(Priority.distance_squared_to_tile_aabb(Vector2(200.0, 4106.0), Vector2i.ZERO, TILE), 100.0),
        "10 m south of tile should be 100 square metres away")
    _check(is_inf(Priority.distance_squared_to_tile_aabb(Vector2.ZERO, Vector2i.ZERO, 0.0)),
        "invalid tile size did not fail closed")

func _test_exact_score_contract() -> void:
    # 96 m from the east tile now, 56 m after exactly two seconds at 20 m/s.
    # 96^2 + 0.2 * 56^2 = 9843.2. This pins the real-data-selected short
    # horizon and weights without depending on the implementation expression.
    var score := Priority.score(Vector2i(1, 0), TILE, Vector2(4000.0, 2000.0), Vector2(20.0, 0.0))
    _check(is_equal_approx(score, 9843.2),
        "short-horizon score contract changed: %f" % score)
    _check(is_equal_approx(Priority.PREDICTION_HORIZON_S, 2.0),
        "prediction horizon drifted from national-trace candidate")
    _check(is_equal_approx(Priority.WEIGHT_PREDICTED, 0.20),
        "prediction weight drifted from national-trace candidate")

func _test_stationary_symmetry() -> void:
    var center := Vector2(TILE * 0.5, TILE * 0.5)
    var east := Priority.score(Vector2i(1, 0), TILE, center, Vector2.ZERO)
    var west := Priority.score(Vector2i(-1, 0), TILE, center, Vector2.ZERO)
    var north := Priority.score(Vector2i(0, -1), TILE, center, Vector2.ZERO)
    var south := Priority.score(Vector2i(0, 1), TILE, center, Vector2.ZERO)
    _check(is_equal_approx(east, west), "stationary east/west symmetry changed")
    _check(is_equal_approx(north, south), "stationary north/south symmetry changed")
    _check(is_equal_approx(east, north), "stationary cardinal symmetry changed")

func _test_cardinal_prediction() -> void:
    var near_east := Vector2(TILE - 46.0, TILE * 0.5)
    var east_score := Priority.score(Vector2i(1, 0), TILE, near_east, Vector2(38.0, 0.0))
    var west_score := Priority.score(Vector2i(-1, 0), TILE, near_east, Vector2(38.0, 0.0))
    var north_score := Priority.score(Vector2i(0, -1), TILE, near_east, Vector2(38.0, 0.0))
    _check(east_score < north_score and east_score < west_score,
        "eastbound boundary approach did not prioritize the travel-direction tile")

    var near_west := Vector2(46.0, TILE * 0.5)
    west_score = Priority.score(Vector2i(-1, 0), TILE, near_west, Vector2(-38.0, 0.0))
    east_score = Priority.score(Vector2i(1, 0), TILE, near_west, Vector2(-38.0, 0.0))
    _check(west_score < east_score, "westbound mirrored case is not symmetric")

    var near_south := Vector2(TILE * 0.5, TILE - 46.0)
    var south_score := Priority.score(Vector2i(0, 1), TILE, near_south, Vector2(0.0, 38.0))
    north_score = Priority.score(Vector2i(0, -1), TILE, near_south, Vector2(0.0, 38.0))
    _check(south_score < north_score, "southbound boundary approach was not prioritized")

func _test_diagonal_prediction() -> void:
    var p := Vector2(TILE - 80.0, TILE - 70.0)
    var diagonal := Priority.score(Vector2i(1, 1), TILE, p, Vector2(28.0, 31.0))
    var opposite := Priority.score(Vector2i(-1, -1), TILE, p, Vector2(28.0, 31.0))
    var lateral := Priority.score(Vector2i(-1, 1), TILE, p, Vector2(28.0, 31.0))
    _check(diagonal < lateral and diagonal < opposite,
        "diagonal travel did not prioritize the southeast tile")

func _test_velocity_clamp() -> void:
    var clamped := Priority.clamp_prediction_velocity(Vector2(1000.0, 0.0))
    _check(is_equal_approx(clamped.length(), Priority.MAX_PREDICTION_SPEED_MPS),
        "teleport/velocity spike exceeded prediction clamp")
    var estimated := Priority.estimate_velocity(Vector2.ZERO, Vector2(1000.0, 0.0), 0.1)
    _check(is_equal_approx(estimated.length(), Priority.MAX_PREDICTION_SPEED_MPS),
        "estimated velocity bypassed prediction clamp")
    _check(Priority.estimate_velocity(Vector2.ZERO, Vector2.ONE, 0.0) == Vector2.ZERO,
        "zero elapsed time did not fail safely")

func _test_stable_tie_break() -> void:
    var center := Vector2(TILE * 0.5, TILE * 0.5)
    _check(Priority.less(Vector2i(-1, 0), Vector2i(1, 0), TILE, center, Vector2.ZERO),
        "equal-score x tie did not resolve deterministically")
    _check(not Priority.less(Vector2i(1, 0), Vector2i(-1, 0), TILE, center, Vector2.ZERO),
        "deterministic x tie-break is not antisymmetric")
    _check(Priority.less(Vector2i(0, -1), Vector2i(0, 1), TILE, center, Vector2.ZERO),
        "equal-score y tie did not resolve deterministically")
    _check(not Priority.less(Vector2i(0, 1), Vector2i(0, -1), TILE, center, Vector2.ZERO),
        "deterministic y tie-break is not antisymmetric")
