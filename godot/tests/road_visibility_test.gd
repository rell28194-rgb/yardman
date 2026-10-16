extends SceneTree

const Runtime = preload("res://scripts/road_visibility_runtime.gd")
var failures := 0

func _init() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("ROAD_VISIBILITY_TEST: " + message)

func _run() -> void:
    var tile := Node3D.new()
    var paved := MeshInstance3D.new()
    paved.name = "paved"
    tile.add_child(paved)
    var dirt := MeshInstance3D.new()
    dirt.name = "dirt"
    tile.add_child(dirt)
    var prop := MeshInstance3D.new()
    prop.name = "RoadSign"
    tile.add_child(prop)

    var changed := Runtime.apply_to_tile(tile, 1700.0)
    _check(changed == 2, "only road surface batches should be budgeted")
    _check(is_equal_approx(paved.visibility_range_end, 1700.0), "paved visibility range missing")
    _check(is_equal_approx(dirt.visibility_range_end, 1700.0), "dirt visibility range missing")
    _check(paved.visibility_range_end_margin > 0.0 and paved.visibility_range_end_margin <= 180.0, "paved fade margin invalid")
    _check(int(paved.visibility_range_fade_mode) == int(GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF), "paved fade mode invalid")
    _check(is_zero_approx(prop.visibility_range_end), "unrelated road props must not inherit surface culling")

    Runtime.apply_to_tile(tile, 99999.0)
    _check(is_equal_approx(paved.visibility_range_end, 3800.0), "upper visibility clamp missing")
    Runtime.apply_to_tile(tile, 10.0)
    _check(is_equal_approx(paved.visibility_range_end, 600.0), "lower visibility clamp missing")

    tile.free()
    if failures == 0:
        print("YARDMAN_ROAD_VISIBILITY_TEST PASS surface_batches=2 clamps=1 props_untouched=1")
        quit()
    else:
        print("YARDMAN_ROAD_VISIBILITY_TEST FAIL failures=%d" % failures)
        quit(1)
