extends SceneTree

const RoadEngineeringDetail = preload("res://scripts/road_engineering_detail_runtime.gd")

func _initialize() -> void:
    var runtime := RoadEngineeringDetail.new()
    var paved := [10.0, 10.0, 70.0, 10.0, 7.0, 5, 0, "w100", 0, 20.0, 22.0,
        [[10.0, 20.0, 6.5], [10.0, 20.0, 13.5], [70.0, 22.0, 13.5], [70.0, 22.0, 6.5]]]
    var bridge := paved.duplicate(true)
    bridge[6] = 2
    bridge[7] = "bridge"
    var tunnel := paved.duplicate(true)
    tunnel[6] = 4
    tunnel[7] = "tunnel"

    var sampler := func(_x: float, z: float) -> float:
        # Uphill terrain to one side, downhill terrain to the other. The resulting
        # cut/fill delta is deliberately deep enough to require a bench.
        return 21.0 + (z - 10.0) * 0.72

    var sections: Array[Dictionary] = runtime.segment_benches(paved, Vector2i.ZERO, 4096.0, sampler, 15.0)
    _require(sections.size() == 5, "60m road should produce four 15m engineering spans")
    var cut_profiles := 0
    var fill_profiles := 0
    for section: Dictionary in sections:
        for side_name in ["left", "right"]:
            if not section.has(side_name):
                continue
            var profile: Dictionary = section[side_name]
            var kind := str(profile.get("kind", ""))
            cut_profiles += int(kind == "cut")
            fill_profiles += int(kind == "fill")
            var inner: Vector3 = profile.inner
            var outer: Vector3 = profile.outer
            _require(inner.distance_to(outer) >= 0.25, "bench width collapsed")
            _require(is_finite(inner.x) and is_finite(inner.y) and is_finite(inner.z), "bench contains non-finite coordinates")
            _require(is_finite(outer.x) and is_finite(outer.y) and is_finite(outer.z), "bench contains non-finite coordinates")
    _require(cut_profiles > 0, "deep uphill side did not create cut bench evidence")
    _require(fill_profiles > 0, "deep downhill side did not create fill bench evidence")

    var geometry := runtime.build_geometry([paved, bridge, tunnel], Vector2i.ZERO, 4096.0, sampler, 15.0)
    _require(int(geometry.cut_bench_spans) > 0, "cut bench geometry missing")
    _require(int(geometry.fill_bench_spans) > 0, "fill bench geometry missing")
    _require(int(geometry.structural_skips) == 2, "bridge/tunnel authority must bypass inferred benches")
    _require(geometry.vertices.size() > 0 and geometry.indices.size() > 0, "engineering detail produced no geometry")
    _require(int(geometry.indices.size()) % 6 == 0, "bench strips are not deterministic quads")

    var flat_sampler := func(_x: float, _z: float) -> float:
        return 21.0
    var flat_geometry := runtime.build_geometry([paved], Vector2i.ZERO, 4096.0, flat_sampler, 15.0)
    _require(flat_geometry.vertices.is_empty(), "shallow terrain should not fabricate hillside benches")
    _require(runtime.segment_benches(bridge, Vector2i.ZERO, 4096.0, sampler, 15.0).is_empty(), "bridge must fail closed")
    _require(runtime.segment_benches(tunnel, Vector2i.ZERO, 4096.0, sampler, 15.0).is_empty(), "tunnel must fail closed")
    _require(runtime.build_geometry([paved], Vector2i.ZERO, 0.0, sampler, 15.0).vertices.is_empty(), "invalid tile size must fail closed")

    runtime.free()
    print("YARDMAN_ROAD_ENGINEERING_DETAIL_TEST PASS cuts=%d fills=%d vertices=%d" % [cut_profiles, fill_profiles, geometry.vertices.size()])
    quit(0)

func _require(condition: bool, message: String) -> void:
    if condition:
        return
    push_error("YARDMAN_ROAD_ENGINEERING_DETAIL_TEST FAIL: " + message)
    quit(2)
