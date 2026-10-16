extends SceneTree

const HLOD = preload("res://scripts/building_hlod_runtime.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("BUILDING_HLOD_TEST: " + message)

func _run() -> void:
    var record := [
        "test-building",
        6.0,
        3,
        0,
        6.0,
        [[
            [0.0, 0.0, 0.0],
            [10.0, 0.0, 0.0],
            [10.0, 0.0, 8.0],
            [0.0, 0.0, 8.0],
        ]],
        [[0.0, 0.0], [10.0, 0.0], [10.0, 8.0], [0.0, 8.0]],
        [0, 1, 2, 0, 2, 3],
    ]
    var geometry := HLOD.record_geometry(record)
    _check(bool(geometry.get("valid", false)), "valid registered footprint was rejected")
    if bool(geometry.get("valid", false)):
        var vertices: PackedVector3Array = geometry.vertices
        var indices: PackedInt32Array = geometry.indices
        _check(vertices.size() == 20, "rectangular proxy should use 16 wall + 4 roof vertices")
        _check(indices.size() == 30, "rectangular proxy should use 8 wall + 2 roof triangles")
        var min_x := INF
        var max_x := -INF
        var min_z := INF
        var max_z := -INF
        var max_y := -INF
        for vertex in vertices:
            min_x = minf(min_x, vertex.x)
            max_x = maxf(max_x, vertex.x)
            min_z = minf(min_z, vertex.z)
            max_z = maxf(max_z, vertex.z)
            max_y = maxf(max_y, vertex.y)
        _check(is_equal_approx(min_x, 0.0) and is_equal_approx(max_x, 10.0), "HLOD changed registered X footprint")
        _check(is_equal_approx(min_z, 0.0) and is_equal_approx(max_z, 8.0), "HLOD changed registered Z footprint")
        _check(is_equal_approx(max_y, 6.0), "HLOD changed registered maximum building height")

    var invalid := HLOD.record_geometry(["bad"])
    _check(not bool(invalid.get("valid", true)), "malformed building record was accepted")

    var performance := HLOD.profile_for_quality("Performance", 450.0, 1.0)
    var ultra := HLOD.profile_for_quality("Ultra", 1450.0, 1.0)
    var hot_ultra := HLOD.profile_for_quality("Ultra", 1450.0, 0.25)
    _check(float(performance.far_distance) < float(ultra.far_distance), "quality tiers do not expand HLOD range")
    _check(int(performance.max_cells) < int(ultra.max_cells), "quality tiers do not expand HLOD cell budget")
    _check(float(hot_ultra.far_distance) < float(ultra.far_distance), "thermal pressure does not reduce HLOD range")
    _check(int(hot_ultra.max_cells) < int(ultra.max_cells), "thermal pressure does not reduce HLOD residency")
    _check(float(hot_ultra.far_distance) >= 1450.0 + 512.0, "thermal HLOD cuts away minimum near-field continuation")

    print("YARDMAN_BUILDING_HLOD_TEST %s footprint=1 height=1 merged_cell=1 thermal_budget=1" % ("PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)
