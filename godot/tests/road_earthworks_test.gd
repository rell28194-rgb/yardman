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
    var cut_bench_count := 0
    var fill_bench_count := 0
    for section: Dictionary in sections:
        _require(section.has("left") and section.has("right"), "both terrain tie-ins should resolve")
        for side_name in ["left", "right"]:
            var profile: Dictionary = section[side_name]
            var kind := str(profile.kind)
            cut_count += int(kind == "cut")
            fill_count += int(kind == "fill")
            ditch_count += int(profile.has("ditch"))
            var has_bench := profile.has("bench_inner") and profile.has("bench_outer")
            bench_count += int(has_bench)
            cut_bench_count += int(has_bench and kind == "cut")
            fill_bench_count += int(has_bench and kind == "fill")
            _require(float(profile.get("tie_run_m", 0.0)) >= 3.5, "earthwork tie run fell below minimum")
            for key in ["edge", "shoulder", "tie"]:
                var point: Vector3 = profile[key]
                _require(is_finite(point.x) and is_finite(point.y) and is_finite(point.z), "earthwork profile contains non-finite coordinates")
            if has_bench:
                var bench_inner: Vector3 = profile.bench_inner
                var bench_outer: Vector3 = profile.bench_outer
                _require(is_finite(bench_inner.x) and is_finite(bench_inner.y) and is_finite(bench_inner.z), "bench inner point is non-finite")
                _require(is_finite(bench_outer.x) and is_finite(bench_outer.y) and is_finite(bench_outer.z), "bench outer point is non-finite")
                _require(bench_inner.distance_to(bench_outer) >= 0.75, "earthwork bench collapsed below minimum width")
                _require(absf(bench_inner.y - bench_outer.y) < 0.001, "earthwork bench must remain level across its width")
    _require(cut_count > 0, "cross-slope did not classify any cut profiles")
    _require(fill_count > 0, "cross-slope did not classify any fill profiles")
    _require(ditch_count > 0, "deep cut did not receive a drainage profile")
    _require(bench_count > 0, "deep terrain did not receive a bench profile")
    _require(cut_bench_count > 0, "deep mountain cut did not receive a cut bench")
    _require(fill_bench_count > 0, "deep embankment did not receive a fill bench")

    var geometry := runtime.build_geometry([paved, bridge, tunnel], Vector2i.ZERO, 4096.0, sampler, 10.0)
    _require(int(geometry.segments) == 1, "bridge/tunnel segments must not receive terrain earthworks")
    _require(int(geometry.structural_skips) == 2, "bridge/tunnel skip accounting changed")
    _require(int(geometry.transition_refined_segments) == 0, "earthworks refined a vertical transition without graph evidence")
    _require(int(geometry.cut_profiles) > 0 and int(geometry.fill_profiles) > 0, "cut/fill geometry accounting missing")
    _require(int(geometry.drainage_profiles) > 0, "procedural drainage geometry accounting missing")
    _require(int(geometry.mapped_drainage_profiles) == 0, "default earthworks invented mapped drainage evidence")
    _require(int(geometry.bench_profiles) > 0, "bench geometry accounting missing")
    _require(int(geometry.cut_bench_profiles) > 0, "cut bench geometry accounting missing")
    _require(int(geometry.fill_bench_profiles) > 0, "fill bench geometry accounting missing")
    var vertices: PackedVector3Array = geometry.vertices
    var collision_faces: PackedVector3Array = geometry.collision_faces
    _require(vertices.size() > 0 and collision_faces.size() > 0, "earthworks did not produce visible/collidable geometry")
    _require(int(geometry.indices.size()) % 6 == 0, "quad index buffer is not triangulated deterministically")
    _require(collision_faces.size() % 3 == 0, "collision faces are not complete triangles")
    _require(runtime.segment_sections(bridge, Vector2i.ZERO, 4096.0, sampler, 10.0).is_empty(), "bridge earthworks must fail closed")
    _require(runtime.segment_sections(tunnel, Vector2i.ZERO, 4096.0, sampler, 10.0).is_empty(), "tunnel earthworks must fail closed")
    _require(runtime.build_geometry([paved], Vector2i.ZERO, 0.0, sampler, 10.0).vertices.is_empty(), "invalid tile size must fail closed")

    # Graph profile evidence does not rewrite the road deck here. It only raises
    # local roadside sampling around a known crest/sag/grade-break boundary so
    # shoulders, cut/fill ties and drainage do not bridge over the transition.
    var transition_query := func(edge_id: String) -> Array:
        if edge_id == "w100":
            return [{"kind": "crest", "vertex_index": 1, "station_m": 40.0,
                "incoming_grade_pct": 5.0, "outgoing_grade_pct": -5.0,
                "grade_break_pct_points": 10.0}]
        return []
    var transition_geometry := runtime.build_geometry(
        [paved], Vector2i.ZERO, 4096.0, sampler, 10.0, Callable(), transition_query)
    _require(int(transition_geometry.transition_refined_segments) == 1,
        "vertical-transition graph evidence did not refine adjacent earthworks")
    _require(transition_geometry.vertices.size() > geometry.vertices.size(),
        "transition-aware earthworks did not increase local roadside sampling")
    _require(int(transition_geometry.structural_skips) == 0,
        "transition-aware refinement altered structural skip accounting")

    var mapped_query := func(_world_point: Vector2, _radius_m: float) -> bool:
        return true
    var mapped_sections: Array[Dictionary] = runtime.segment_sections(paved, Vector2i.ZERO, 4096.0, sampler, 10.0, mapped_query)
    var mapped_cut_count := 0
    for section: Dictionary in mapped_sections:
        for side_name in ["left", "right"]:
            var profile: Dictionary = section[side_name]
            if str(profile.kind) != "cut" or float(profile.delta_y) < runtime.CUT_DITCH_THRESHOLD_M:
                continue
            mapped_cut_count += 1
            _require(bool(profile.get("mapped_drainage", false)), "explicit drainage evidence was not recorded on cut profile")
            _require(not profile.has("ditch"), "mapped drainage evidence must suppress duplicate procedural ditch")
    _require(mapped_cut_count > 0, "test road did not produce any mapped-drainage cut profiles")
    var mapped_geometry := runtime.build_geometry([paved], Vector2i.ZERO, 4096.0, sampler, 10.0, mapped_query)
    _require(int(mapped_geometry.mapped_drainage_profiles) == mapped_cut_count,
        "mapped drainage profile accounting changed")
    _require(int(mapped_geometry.drainage_profiles) == 0,
        "explicit mapped drainage must outrank duplicate procedural cut-side ditch geometry")

    var accelerating_sampler := func(_x: float, z: float) -> float:
        var dz := absf(z - 10.0)
        return 10.0 + dz * dz * 0.08
    var accelerating := runtime.segment_sections(paved, Vector2i.ZERO, 4096.0, accelerating_sampler, 10.0)
    var max_tie_run := 0.0
    for section: Dictionary in accelerating:
        for side_name in ["left", "right"]:
            max_tie_run = maxf(max_tie_run, float(section[side_name].get("tie_run_m", 0.0)))
    _require(max_tie_run > 10.0, "outer terrain resample did not expand steepening cut tie run")

    var fill_sampler := func(_x: float, _z: float) -> float:
        return 3.0
    var fill_geometry := runtime.build_geometry([paved], Vector2i.ZERO, 4096.0, fill_sampler, 10.0)
    _require(int(fill_geometry.fill_profiles) > 0, "low terrain did not classify as embankment fill")
    _require(int(fill_geometry.fill_bench_profiles) > 0, "deep fill did not receive consolidated bench geometry")
    _require(int(fill_geometry.cut_bench_profiles) == 0, "fill-only terrain invented cut benches")
    _require(fill_geometry.vertices.size() > 0 and fill_geometry.collision_faces.size() > 0, "fill bench did not produce collidable geometry")

    runtime.free()
    print("YARDMAN_ROAD_EARTHWORKS_TEST PASS sections=%d cuts=%d fills=%d drainage=%d cut_benches=%d fill_benches=%d mapped=%d transition_refined=%d vertices=%d" % [
        sections.size(), cut_count, fill_count, ditch_count, cut_bench_count, fill_bench_count, mapped_cut_count,
        int(transition_geometry.transition_refined_segments), vertices.size()])
    quit(0)

func _require(condition: bool, message: String) -> void:
    if condition:
        return
    push_error("YARDMAN_ROAD_EARTHWORKS_TEST FAIL: " + message)
    quit(2)
