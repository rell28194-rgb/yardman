extends SceneTree

const Runtime = preload("res://scripts/parish_runtime.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("PARISH_RUNTIME_TEST: " + message)

func _rect(x0: float, z0: float, x1: float, z1: float) -> Dictionary:
    return {
        "bounds": [x0, z0, x1, z1],
        "rings": [[[x0, z0], [x1, z0], [x1, z1], [x0, z1], [x0, z0]]],
    }

func _manifest() -> Dictionary:
    var parishes := {}
    for index in range(Runtime.CANONICAL_PARISHES.size()):
        var x0 := float(index) * 100.0
        parishes[str(Runtime.CANONICAL_PARISHES[index])] = [_rect(x0, 0.0, x0 + 100.0, 100.0)]
    return {
        "authority": "test admin polygons",
        "crs": "EPSG:3448",
        "source_sha256": "test",
        "parishes": parishes,
    }

func _run() -> void:
    var runtime = Runtime.new()
    var manifest := _manifest()
    _check(runtime.load_manifest(manifest), "valid canonical manifest was rejected")
    _check(runtime.is_ready(), "runtime did not enter ready state")
    _check(runtime.parish_names().size() == 14, "runtime does not expose exactly fourteen canonical parishes")
    _check(runtime.parish_at(50.0, 50.0) == "Kingston", "interior point did not resolve to Kingston")
    _check(runtime.parish_at(150.0, 50.0) == "St. Andrew", "interior point resolved to wrong adjacent parish")
    _check(runtime.parish_at(100.0, 50.0).is_empty(), "shared administrative edge must remain explicit ambiguity")
    _check(runtime.parish_at(NAN, 50.0).is_empty(), "invalid coordinate must fail closed")
    _check(runtime.parish_at(-1.0, 50.0).is_empty(), "point outside national bounds was accepted")
    var map_data: Dictionary = runtime.map_data()
    _check(map_data.bounds.size() == 4 and is_equal_approx(float(map_data.bounds[0]), 0.0) and is_equal_approx(float(map_data.bounds[2]), 1400.0), "national map bounds were not derived from source polygons")
    _check(runtime.set_current_parish("Portland") and runtime.current_parish == "Portland", "canonical current parish update failed")
    _check(not runtime.set_current_parish("Not a parish") and runtime.current_parish == "Portland", "non-canonical parish was accepted")

    var incomplete = Runtime.new()
    var broken := _manifest()
    var broken_parishes: Dictionary = broken["parishes"]
    broken_parishes.erase("St. Thomas")
    _check(not incomplete.load_manifest(broken), "thirteen-parish manifest did not fail closed")
    _check(not incomplete.is_ready() and incomplete.map_data().parishes.is_empty(), "failed load retained stale parish geometry")

    runtime.free()
    incomplete.free()
    print("YARDMAN_PARISH_RUNTIME_TEST %s canonical=14 polygon_truth=1 ambiguity=1 fail_closed=1" % ["PASS" if failures == 0 else "FAIL"])
    quit(0 if failures == 0 else 1)
