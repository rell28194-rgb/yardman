extends SceneTree

const RoadsideEngineering = preload("res://scripts/roadside_engineering_runtime.gd")

func _initialize() -> void:
    var runtime := RoadsideEngineering.new()
    var road := [10.0, 10.0, 50.0, 10.0, 7.0, 5, 0, "w100", 0, 10.0, 10.0,
        [[10.0, 10.0, 6.5], [10.0, 10.0, 13.5], [50.0, 10.0, 13.5], [50.0, 10.0, 6.5]]]
    var bridge := road.duplicate(true)
    bridge[6] = 2
    bridge[7] = "bridge"
    var tunnel := road.duplicate(true)
    tunnel[6] = 4
    tunnel[7] = "tunnel"
    var sampler := func(_x: float, z: float) -> float:
        # Across-road terrain: low on one side, high on the other. The high side
        # proves a cut is needed, but does not prove a hard retaining wall exists.
        return 12.0 + (z - 10.0) * 0.8

    var sections := runtime.sample_sections(road, Vector2i.ZERO, 4096.0, sampler, 10.0)
    _require(sections.size() == 5, "40m road should produce five sampled engineering sections")
    var delegated_cuts := 0
    var retaining := 0
    var safety := 0
    for section: Dictionary in sections:
        for side_name in ["left", "right"]:
            var profile: Dictionary = section[side_name]
            var kind := str(profile.kind)
            delegated_cuts += int(kind == "earthwork_cut")
            retaining += int(kind == "retaining")
            safety += int(kind == "safety")
            if kind == "safety":
                var base: Vector3 = profile.base
                var top: Vector3 = profile.top
                _require(is_finite(base.x) and is_finite(base.y) and is_finite(base.z), "engineering base is non-finite")
                _require(is_finite(top.x) and is_finite(top.y) and is_finite(top.z), "engineering top is non-finite")
                _require(top.y > base.y, "engineering safety visual has non-positive height")
    _require(delegated_cuts > 0, "high cut was not delegated to soft road earthworks")
    _require(retaining == 0, "DEM-only cut must not invent a hard retaining wall")
    _require(safety > 0, "deep fill/drop did not produce inferred safety treatment")

    var geometry := runtime.build_geometry([road, bridge, tunnel], Vector2i.ZERO, 4096.0, sampler, 10.0)
    _require(int(geometry.retaining_spans) == 0, "DEM-only geometry must not contain inferred retaining spans")
    _require(int(geometry.earthwork_cut_spans) == 4, "cut delegation span count changed")
    _require(int(geometry.safety_spans) == 4, "safety span count changed")
    _require(int(geometry.mapped_safety_suppressed_spans) == 0, "unsourced run was incorrectly suppressed")
    _require(int(geometry.structural_skips) == 2, "bridge/tunnel authority must suppress inferred roadside treatment")
    _require(geometry.vertices.size() == 16, "only four safety quads should be rendered by roadside engineering")
    _require(geometry.indices.size() == 24, "safety quads were not triangulated deterministically")

    # Explicit OSM guard-rail authority must suppress the inferred visual rail on
    # the drop side while leaving cut delegation untouched.
    var mapped_guardrail := func(_world_point: Vector2, radius_m: float) -> bool:
        _require(is_equal_approx(radius_m, runtime.MAPPED_GUARDRAIL_SUPPRESSION_RADIUS_M),
            "roadside guardrail query radius changed unexpectedly")
        return true
    var mapped := runtime.build_geometry([road], Vector2i.ZERO, 4096.0, sampler, 10.0, mapped_guardrail)
    _require(int(mapped.earthwork_cut_spans) == 4, "mapped guardrail query interfered with cut delegation")
    _require(int(mapped.safety_spans) == 0, "inferred safety rail duplicated explicit guardrail authority")
    _require(int(mapped.mapped_safety_suppressed_spans) == 4, "explicit guardrail suppression count changed")
    _require(mapped.vertices.is_empty(), "explicit guardrail authority should leave no duplicate inferred rail geometry")

    var flat_sampler := func(_x: float, _z: float) -> float:
        return 10.2
    var flat := runtime.build_geometry([road], Vector2i.ZERO, 4096.0, flat_sampler, 10.0)
    _require(flat.vertices.is_empty(), "nearly level roadside terrain must not invent structures")
    _require(int(flat.earthwork_cut_spans) == 0, "level terrain must not delegate nonexistent cuts")

    var cut_only_sampler := func(_x: float, _z: float) -> float:
        return 14.0
    var cut_only := runtime.build_geometry([road], Vector2i.ZERO, 4096.0, cut_only_sampler, 10.0)
    _require(int(cut_only.earthwork_cut_spans) == 8, "bilateral high cuts should be delegated on every span")
    _require(int(cut_only.retaining_spans) == 0, "bilateral high cuts invented retaining walls")
    _require(cut_only.vertices.is_empty(), "delegated cut-only treatment should not duplicate earthworks geometry")

    var narrow := road.duplicate(true)
    narrow[4] = 3.0
    _require(runtime.sample_sections(narrow, Vector2i.ZERO, 4096.0, sampler, 10.0).is_empty(),
        "narrow tracks must fail closed instead of receiving highway-scale engineering")

    runtime.free()
    print("YARDMAN_ROADSIDE_ENGINEERING_TEST PASS delegated_cuts=%d retaining=%d safety=%d mapped_suppressed=%d vertices=%d" % [
        delegated_cuts, retaining, safety, int(mapped.mapped_safety_suppressed_spans), geometry.vertices.size()])
    quit(0)

func _require(condition: bool, message: String) -> void:
    if condition:
        return
    push_error("YARDMAN_ROADSIDE_ENGINEERING_TEST FAIL: " + message)
    quit(2)
