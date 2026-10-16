extends SceneTree

const Variety = preload("res://scripts/traffic_visual_variety_runtime.gd")
const Catalog = preload("res://scripts/vehicle_catalog.gd")
var failures := 0

func _init() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("TRAFFIC_VISUAL_VARIETY_TEST: " + message)

func _run() -> void:
    var a := Variety.variant_for("edge-101:1")
    var b := Variety.variant_for("edge-101:1")
    _check(a == b, "traffic visual assignment is not deterministic")
    _check(Catalog.has(str(a.vehicle_id)), "traffic visual assignment returned unknown profile")
    _check(a.paint_rgb is Array and a.paint_rgb.size() == 3, "traffic paint variant is malformed")
    for channel in a.paint_rgb:
        _check(float(channel) >= 0.0 and float(channel) <= 1.0, "traffic paint channel left normalized range")

    var styles: Dictionary = {}
    var paints: Dictionary = {}
    for index in range(64):
        var variant := Variety.variant_for("traffic-edge-%d:%d" % [index, 1 if index % 2 == 0 else -1])
        styles[str(variant.vehicle_id)] = true
        paints[str(variant.paint_rgb)] = true
        _check(Catalog.has(str(variant.vehicle_id)), "sampled traffic style missing from catalog")
    _check(styles.size() >= 3, "deterministic traffic sample did not exercise style variety")
    _check(paints.size() >= 5, "deterministic traffic sample did not exercise paint variety")

    if failures == 0:
        print("YARDMAN_TRAFFIC_VISUAL_VARIETY_TEST PASS deterministic=1 catalog=1 normalized=3 style_variety=%d paint_variety=%d" % [styles.size(), paints.size()])
        quit()
    else:
        print("YARDMAN_TRAFFIC_VISUAL_VARIETY_TEST FAIL failures=%d" % failures)
        quit(1)
