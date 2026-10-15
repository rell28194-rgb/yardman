extends SceneTree

const RoadEarthworks = preload("res://scripts/road_earthworks_runtime.gd")

func _initialize() -> void:
    var runtime := RoadEarthworks.new()
    var paved := [10.0, 10.0, 50.0, 10.0, 7.0, 5, 0, "w100", 0, 10.0, 12.0,
        [[10.0, 10.0, 6.5], [10.0, 10.0, 13.5], [50.0, 12.0, 13.5], [50.0, 12.0, 6.5]]]
    var bridge := paved.duplicate(true)
    bridge[6] = 2
    bridge[7] = "bridge"
    var tunnel := paved.duplicate(true)
    tunnel[6] = 4
    tunnel[7] = "tunnel"
    var sampler := func(_x: float, z: float) -> float:
        # Cross-slope deliberately places one road side in cut and the other in fill.
        return 11.0 + (z - 10.0) * 0.55

    var sections: Array[Dictionary] = runtime.segment_sections(paved, Vector2i.ZERO, 4096.0, sampler, 10.0)
    _require(sections.size() == 5, "40m clipped road should produce four 10m earthwork spans")
    var cut_count := 0
    var fill_count := 0
    var ditch_count := 0
    var bench_count := 0
    for section: Dictionary in sections:
        _require(section.has("left") and section.has("right"), "both terrain tie-ins should resolve")
        for side_name in ["left", "right"]:
            var profile: Dictionary = section[side_name]
            var kind := str(profile.kind)
            cut_count += int(kind == "cut")
            fill_count += int(kind == "fill")
            ditch_count += int(profile.has("ditch"))
            bench_count += int(profile.has("bench_inner") and profile.has("bench_outer"))
            _require(float(profile.get("tie_run_m", 0.0)) >= 3.5, "earthwork tie run fell below minimum")
            for key in ["edge", "shoulder", "tie"]:
                var point: Vector3 = profile[key]
                _require(is_finite(point.x) and is_finite(point.y) and is_finite(point.z), "earthwork profile contains non-finite coordinates")
            if profile.has("bench_inner") and profile.has("bench_outer"):
                var bench_inner: Vector3 = profile.bench_inner
                var bench_outer: Vector3 = profile.bench_outer
                _require(is_finite(bench_inner.x) and is_finite(bench_inner.y) and is_finite(bench_inner.z), "cut bench inner point is non-finite")
                _require(is_finite(bench_outer.x) and is_finite(bench_outer.y) and is_finite(bench_outer.z), "cut bench outer point is non-finite")
                _require(bench_inner.distance_to(bench_outer) >= 0.75, "cut bench collapsed below minimum width")
                _require(absf(bench_inner.y - bench_outer.y) < 0.001, "cut bench must remain level across its width")
    _require(cut_count > 0, "cross-slope did not classify any cut profiles")
    _require(fill_count > 0, "cross-slope did not classify any fill profiles")
    _require(ditch_count > 0, "deep cut did not receive a drainage profile")
    _require(bench_count > 0, "deep mountain cut did not receive a bench profile")

    var geometry := runtime.build_geometry([paved, bridge, tunnel], Vector2i.ZERO, 4096.0, sampler, 10.0)
    _require(int(geometry.segments) == 1, "bridge/tunnel segments must not receive terrain earthworks")
    _require(int(geometry.structural_skips) == 2, "bridge/tunnel skip accounting changed")
    _require(int(geometry.cut_profiles) > 0 and int(geometry.fill_profiles) > 0, "cut/fill geometry accounting missing")
    _require(int(geometry.drainage_profiles) > 0, "drainage geometry accounting missing")
    _require(int(geometry.bench_profiles) > 0, "bench geometry accounting missing")
    var vertices: PackedVector3Array = geometry.vertices
    var collision_faces: PackedVector3Array = geometry.collision_faces
    _require(vertices.size() > 0 and collision_faces.size() > 0, "earthworks did not produce visible/collidable geometry")
    _require(int(geometry.indices.size()) % 6 == 0, "quad index buffer is not triangulated deterministically")
    _require(collision_faces.size() % 3 == 0, "collision faces are not complete triangles")
    _require(runtime.segment_sections(bridge, Vector2i.ZERO, 4096.0, sampler, 10.0).is_empty(), "bridge earthworks must fail closed")
    _require(runtime.segment_sections(tunnel, Vector2i.ZERO, 4096.0, sampler, 10.0).is_empty(), "tunnel earthworks must fail closed")
    _require(runtime.build_geometry([paved], Vector2i.ZERO, 0.0, sampler, 10.0).vertices.is_empty(), "invalid tile size must fail closed")

    var accelerating_sampler := func(_x: float, z: float) -> float:
        var dz := absf(z - 10.0)
        return 10.0 + dz * dz * 0.08
    var accelerating := runtime.segment_sections(paved, Vector2i.ZERO, 4096.0, accelerating_sampler, 10.0)
    var max_tie_run := 0.0
    for section: Dictionary in accelerating:
        for side_name in ["left", "right"]:
            max_tie_run = maxf(max_tie_run, float(section[side_name].get("tie_run_m", 0.0)))
    _require(max_tie_run > 10.0, "outer terrain resample did not expand steepening cut tie run")

    runtime.free()
    print("YARDMAN_ROAD_EARTHWORKS_TEST PASS sections=%d cuts=%d fills=%d drainage=%d benches=%d vertices=%d" % [sections.size(), cut_count, fill_count, ditch_count, bench_count, vertices.size()])
    quit(0)

func _require(condition: bool, message: String) -> void:
    if condition:
        return
    push_error("YARDMAN_ROAD_EARTHWORKS_TEST FAIL: " + message)
    quit(2)
