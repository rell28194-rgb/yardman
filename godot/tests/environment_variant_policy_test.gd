extends SceneTree

const Policy = preload("res://scripts/environment_variant_policy.gd")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("ENVIRONMENT_VARIANT_POLICY: " + message)
    quit(1)

func _run() -> void:
    var trees: Array = [
        {"variant":"coastal_a"}, {"variant":"coastal_b"},
        {"variant":"coastal_c"}, {"variant":"broadleaf"},
    ]
    var shrubs: Array = [
        {"variant":"flowering"}, {"variant":"meadow"}, {"variant":"fern_wet"},
    ]
    var key := "Roadside_14_-7_broadleaf"
    var first := Policy.choose("tree_near", trees, key, 120.0)
    var second := Policy.choose("tree_near", trees, key, 120.0)
    if first != second or first < 0 or first > 2:
        _fail("lowland tree choice is not stable/coastal")
        return
    if Policy.choose("tree_near", trees, key, 720.0) != 3:
        _fail("highland broadleaf bias failed")
        return
    if Policy.choose("shrub_near", shrubs, "ShrubCell_3_9", 380.0) != 2:
        _fail("wet highland fern bias failed")
        return
    var low_shrub := Policy.choose("shrub_near", shrubs, "ShrubCell_3_9", 80.0)
    if low_shrub < 0 or low_shrub > 1:
        _fail("lowland shrub should use flowering/meadow pool")
        return
    if Policy.choose("grass_near", [{"variant":"lush"}], "GrassCell", 40.0) != 0:
        _fail("single grass variant failed")
        return
    print("YARDMAN_ENVIRONMENT_VARIANT_POLICY_PASS stable=1 coastal=3 highland_broadleaf=1 wet_fern=1")
    quit(0)
