extends SceneTree

const GuardRailLayer = preload("res://scripts/guardrail_layer.gd")

func _initialize() -> void:
    var layer := GuardRailLayer.new()
    var records := [
        {"source_way": "w1", "segment": 0, "start": [-1320.0, -3025.0], "end": [-1310.0, -3025.0], "barrier": "guard_rail", "material": "unspecified"},
        {"source_way": "w2", "segment": 0, "start": [-1320.0, -3010.0], "end": [-1310.0, -3010.0], "barrier": "fence"},
        {"source_way": "wrong-tile", "segment": 0, "start": [5000.0, 5000.0], "end": [5010.0, 5000.0], "barrier": "guard_rail"},
    ]
    var plan: Array[Dictionary] = layer.placement_plan(records, Vector2i(-1, -1), 4096.0, 3.75)
    _require(plan.size() == 3, "10m explicit guard rail should split into three bounded spans")
    for span: Dictionary in plan:
        _require(str(span.source_way) == "w1", "non-guard-rail or wrong-tile geometry was accepted")
        var length := Vector2(float(span.world_ax), float(span.world_az)).distance_to(Vector2(float(span.world_bx), float(span.world_bz)))
        _require(length > 0.05 and length <= 3.75 + 0.001, "span escaped maximum procedural length")
        _require(str(span.material) == "unspecified", "runtime invented guard-rail material")
    _require(layer.placement_plan(records, Vector2i(-1, -1), 0.0, 3.75).is_empty(), "invalid tile size must fail closed")
    _require(layer.placement_plan(records, Vector2i(-1, -1), 4096.0, 0.0).is_empty(), "invalid max span must fail closed")

    # Inject the same compiled-record shape into the cache so the proximity query
    # can be exercised without depending on the production Jamaica dataset being
    # present in a unit-test checkout.
    layer._record_cache[layer._cache_key(Vector2i(-1, -1))] = records
    _require(layer.has_mapped_guardrail_near(Vector2(-1315.0, -3024.0), 1.1),
        "explicit sourced guardrail was not found by proximity authority query")
    _require(not layer.has_mapped_guardrail_near(Vector2(-1315.0, -3021.0), 1.1),
        "guardrail proximity query escaped its requested radius")
    _require(not layer.has_mapped_guardrail_near(Vector2(-1315.0, -3010.0), 1.1),
        "non-guard-rail barrier incorrectly became safety authority")
    _require(not layer.has_mapped_guardrail_near(Vector2(INF, 0.0), 2.0),
        "non-finite guardrail query must fail closed")
    _require(not layer.has_mapped_guardrail_near(Vector2(-1315.0, -3025.0), 0.0),
        "non-positive guardrail query radius must fail closed")

    layer._ensure_meshes()
    _require(layer._beam_mesh != null and layer._post_mesh != null, "procedural guard-rail meshes missing")
    _require(is_equal_approx(layer._beam_mesh.size.y, 0.30) and is_equal_approx(layer._beam_mesh.size.z, 0.14), "beam dimensions changed")
    _require(is_equal_approx(layer._post_mesh.size.y, 0.78), "post dimensions changed")
    layer.free()
    print("YARDMAN_GUARDRAIL_LAYER_TEST PASS spans=%d proximity=explicit-only" % plan.size())
    quit(0)

func _require(condition: bool, message: String) -> void:
    if condition:
        return
    push_error("YARDMAN_GUARDRAIL_LAYER_TEST FAIL: " + message)
    quit(2)
