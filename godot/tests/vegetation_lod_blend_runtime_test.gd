extends SceneTree

const LodBlend = preload("res://scripts/vegetation_lod_blend_runtime.gd")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("VEGETATION_LOD_BLEND_RUNTIME_TEST: " + message)
    quit(1)

func _make_instance(name_value: String, begin_m: float, end_m: float, distant := false, grass := false) -> MultiMeshInstance3D:
    var instance := MultiMeshInstance3D.new()
    instance.name = name_value
    instance.visibility_range_begin = begin_m
    instance.visibility_range_end = end_m
    if distant:
        instance.set_meta("distant", true)
    if grass:
        instance.set_meta("grass", true)
    return instance

func _run() -> void:
    var helper := LodBlend.new()
    var roadside := Node3D.new()
    roadside.name = "RoadsideProxy"
    root.add_child(roadside)

    var near_tree := _make_instance("Plants_0_0_broadleaf", 0.0, 220.0)
    var far_tree := _make_instance("Plants_0_0_broadleaf_Distant", 220.0, 1000.0, true, false)
    var near_shrub := _make_instance("Plants_0_0_shrub", 0.0, 95.0)
    var far_shrub := _make_instance("Plants_0_0_shrub_Distant", 95.0, 470.0, true, false)
    var grass := _make_instance("Plants_0_0_broadleaf_Grass", 0.0, 150.0, false, true)
    for instance in [near_tree, far_tree, near_shrub, far_shrub, grass]:
        roadside.add_child(instance)
        if not helper._configure_instance(weakref(instance)):
            _fail("failed to configure " + str(instance.name))
            return
        if instance.visibility_range_fade_mode != GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF:
            _fail("fade mode not enabled for " + str(instance.name))
            return
        if not bool(instance.get_meta("lod_blend_configured", false)):
            _fail("configured metadata missing")
            return

    if not is_equal_approx(near_tree.visibility_range_end_margin, LodBlend.TREE_MARGIN_M):
        _fail("tree near end margin incorrect")
        return
    if not is_equal_approx(far_tree.visibility_range_begin_margin, LodBlend.TREE_MARGIN_M):
        _fail("tree distant begin margin incorrect")
        return
    if not is_equal_approx(near_shrub.visibility_range_end_margin, LodBlend.SHRUB_MARGIN_M):
        _fail("shrub near end margin incorrect")
        return
    if not is_equal_approx(far_shrub.visibility_range_begin_margin, LodBlend.SHRUB_MARGIN_M):
        _fail("shrub distant begin margin incorrect")
        return
    if not is_equal_approx(grass.visibility_range_end_margin, LodBlend.GRASS_MARGIN_M):
        _fail("grass fade margin incorrect")
        return
    if helper.configured_near != 2 or helper.configured_distant != 2 or helper.configured_grass != 1:
        _fail("configuration counters incorrect")
        return
    if helper._configure_instance(weakref(near_tree)):
        _fail("instance was configured twice")
        return

    var unrelated_parent := Node3D.new()
    unrelated_parent.name = "Other"
    root.add_child(unrelated_parent)
    var unrelated := _make_instance("OtherVegetation", 0.0, 200.0)
    unrelated_parent.add_child(unrelated)
    if helper._configure_instance(weakref(unrelated)):
        _fail("non-roadside vegetation was modified")
        return

    unrelated_parent.free()
    roadside.free()
    helper.free()
    print("YARDMAN_VEGETATION_LOD_BLEND_RUNTIME_TEST PASS near=2 distant=2 grass=1 overlap=1 duplicate_safe=1 unrelated=0")
    quit(0)
