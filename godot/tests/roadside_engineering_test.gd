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
        # Across-road terrain: low on one side, high on the other. This mimics a
        # bench-cut mountain road where fill/drop protection and cut retention
        # are both plausible even though neither structure was explicitly mapped.
        return 12.0 + (z - 10.0) * 0.8

    var sections := runtime.sample_sections(road, Vector2i.ZERO, 4096.0, sampler, 10.0)
    _require(sections.size() == 5, "40m road should produce five sampled engineering sections")
    var retaining := 0
    var safety := 0
    for section: Dictionary in sections:
        for side_name in ["left", "right"]:
            var profile: Dictionary = section[side_name]
            retaining += int(str(profile.kind) == "retaining")
            safety += int(str(profile.kind) == "safety")
            if str(profile.kind) in ["retaining", "safety"]:
                var base: Vector3 = profile.base
                var top: Vector3 = profile.top
                _require(is_finite(base.x) and is_finite(base.y) and is_finite(base.z), "engineering base is non-finite")
                _require(is_finite(top.x) and is_finite(top.y) and is_finite(top.z), "engineering top is non-finite")
                _require(top.y > base.y, "engineering visual has non-positive height")
    _require(retaining > 0, "high cut did not produce inferred retaining treatment")
    _require(safety > 0, "deep fill/drop did not produce inferred safety treatment")

    var geometry := runtime.build_geometry([road, bridge, tunnel], Vector2i.ZERO, 4096.0, sampler, 10.0)
    _require(int(geometry.retaining_spans) == 4, "retaining span count changed")
    _require(int(geometry.safety_spans) == 4, "safety span count changed")
    _require(int(geometry.structural_skips) == 2, "bridge/tunnel authority must suppress inferred roadside treatment")
    _require(geometry.vertices.size() == 32, "expected eight visual engineering quads")
    _require(geometry.indices.size() == 48, "engineering quads were not triangulated deterministically")

    var flat_sampler := func(_x: float, _z: float) -> float:
        return 10.2
    var flat := runtime.build_geometry([road], Vector2i.ZERO, 4096.0, flat_sampler, 10.0)
    _require(flat.vertices.is_empty(), "nearly level roadside terrain must not invent structures")

    var narrow := road.duplicate(true)
    narrow[4] = 3.0
    _require(runtime.sample_sections(narrow, Vector2i.ZERO, 4096.0, sampler, 10.0).is_empty(),
        "narrow tracks must fail closed instead of receiving highway-scale engineering")

    runtime.free()
    print("YARDMAN_ROADSIDE_ENGINEERING_TEST PASS retaining=%d safety=%d vertices=%d" % [
        retaining, safety, geometry.vertices.size()])
    quit(0)

func _require(condition: bool, message: String) -> void:
    if condition:
        return
    push_error("YARDMAN_ROADSIDE_ENGINEERING_TEST FAIL: " + message)
    quit(2)
