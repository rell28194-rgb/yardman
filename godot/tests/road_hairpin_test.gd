extends SceneTree

const Hairpins = preload("res://scripts/road_hairpin_runtime.gd")

func _initialize() -> void:
    var runtime := Hairpins.new()
    var first := [0.0, 0.0, 20.0, 0.0, 6.0, 5, 0, "edge", 0, 10.0, 11.0,
        [[0.0, 10.0, -3.0], [0.0, 10.0, 3.0], [20.0, 11.0, 3.0], [20.0, 11.0, -3.0]]]
    var second := [20.0, 0.0, 20.0, 20.0, 6.0, 5, 0, "edge", 1, 11.0, 12.0,
        [[17.0, 11.0, 0.0], [23.0, 11.0, 0.0], [23.0, 12.0, 20.0], [17.0, 12.0, 20.0]]]
    var straight := [20.0, 0.0, 40.0, 0.0, 6.0, 5, 0, "straight", 1, 11.0, 12.0,
        [[20.0, 11.0, -3.0], [20.0, 11.0, 3.0], [40.0, 12.0, 3.0], [40.0, 12.0, -3.0]]]

    var record := runtime.bend_record(first, second)
    _require(not record.is_empty(), "90-degree mountain bend was not detected")
    _require(absf(float(record.turn_deg) - 90.0) < 0.01, "turn angle changed")
    _require(float(record.widen_m) > 0.55, "sharp bend did not widen outside shoulder")
    _require(runtime.bend_record(first, straight).is_empty(), "straight continuation invented a bend apron")

    var geometry := runtime.build_geometry([first, second], Vector2i.ZERO, 4096.0)
    _require(int(geometry.sharp_bends) == 1, "sharp bend count changed")
    _require(int(geometry.hairpins) == 0, "90-degree bend must not be classified as hairpin")
    _require(geometry.vertices.size() == 8, "bend widening should emit two deterministic quads")
    _require(geometry.indices.size() == 12 and geometry.collision_faces.size() == 12,
        "bend apron mesh/collision triangulation changed")

    var reverse := [20.0, 0.0, 2.0, 7.0, 6.0, 5, 0, "edge", 1, 11.0, 12.0,
        [[20.0, 11.0, -3.0], [20.0, 11.0, 3.0], [2.0, 12.0, 10.0], [0.0, 12.0, 4.0]]]
    var hairpin := runtime.bend_record(first, reverse)
    _require(not hairpin.is_empty() and float(hairpin.turn_deg) >= runtime.HAIRPIN_TURN_DEG,
        "switchback geometry was not classified as hairpin")
    var hairpin_geometry := runtime.build_geometry([first, reverse], Vector2i.ZERO, 4096.0)
    _require(int(hairpin_geometry.hairpins) == 1, "hairpin count changed")
    _require(float(hairpin.widen_m) > float(record.widen_m), "hairpin should receive more widening than 90-degree bend")

    var bridge := second.duplicate(true)
    bridge[6] = 2
    _require(runtime.bend_record(first, bridge).is_empty(), "bridge approach must retain structural authority")
    var narrow := first.duplicate(true)
    narrow[4] = 3.0
    var narrow_geometry := runtime.build_geometry([narrow, second], Vector2i.ZERO, 4096.0)
    _require(narrow_geometry.vertices.is_empty(), "narrow track received highway-scale bend widening")
    _require(runtime.build_geometry([first, second], Vector2i.ZERO, 0.0).vertices.is_empty(),
        "invalid tile size must fail closed")

    runtime.free()
    print("YARDMAN_ROAD_HAIRPIN_TEST PASS turn=%.1f widen=%.2f hairpin=%.1f" % [
        float(record.turn_deg), float(record.widen_m), float(hairpin.turn_deg)])
    quit(0)

func _require(condition: bool, message: String) -> void:
    if condition:
        return
    push_error("YARDMAN_ROAD_HAIRPIN_TEST FAIL: " + message)
    quit(2)
