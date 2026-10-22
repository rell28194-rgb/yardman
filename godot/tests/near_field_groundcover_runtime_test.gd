extends SceneTree

const Groundcover = preload("res://scripts/near_field_groundcover_runtime.gd")

class FakeRoads extends Node:
    var tile_size := 256.0

class FakeTerrain extends Node:
    var calls := 0
    func height_at(_x: float, _z: float) -> float:
        calls += 1
        return 5.0

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("NEAR_FIELD_GROUNDCOVER_RUNTIME_TEST: " + message)
    quit(1)

func _run() -> void:
    var helper := Groundcover.new()
    var fake_roads := FakeRoads.new()
    var fake_terrain := FakeTerrain.new()
    helper.roads = fake_roads
    helper.terrain = fake_terrain
    helper.density_factor_override = 1.0

    var tile_root := Node3D.new()
    root.add_child(tile_root)
    var segment := [16.0, 128.0, 240.0, 128.0, 6.0, 1, 0, "edge-a", 0, 5.0, 5.0]
    helper._build_tile(Vector2i.ZERO, tile_root, [segment])

    var groundcover := tile_root.get_node_or_null("NearFieldGroundcover") as Node3D
    if groundcover == null:
        _fail("groundcover root missing")
        return
    var anchors := int(groundcover.get_meta("anchor_count", 0))
    if anchors != 38:
        _fail("expected 38 deterministic anchors, got %d" % anchors)
        return
    if groundcover.get_child_count() != 1:
        _fail("single 256 m cell should remain one MultiMesh batch")
        return
    var cell := groundcover.get_child(0) as MultiMeshInstance3D
    if cell == null or cell.multimesh == null:
        _fail("groundcover cell is not a MultiMesh")
        return
    if cell.multimesh.instance_count != anchors or int(cell.get_meta("source_anchors", 0)) != anchors:
        _fail("source anchor count does not match MultiMesh count")
        return
    if cell.multimesh.instance_count > Groundcover.MAX_ANCHORS_PER_CELL:
        _fail("cell anchor cap exceeded")
        return
    if cell.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
        _fail("near-field groundcover should not cast shadows on Android")
        return
    if not is_equal_approx(cell.visibility_range_end, Groundcover.VISIBILITY_M):
        _fail("unexpected groundcover visibility range")
        return
    if cell.visibility_range_fade_mode != GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF:
        _fail("groundcover distance fade is disabled")
        return
    if str(cell.name).to_lower().ends_with("_grass"):
        _fail("dedicated groundcover must not be multiplied again by legacy grass densifier")
        return

    var positive_side := 0
    var negative_side := 0
    for index in range(cell.multimesh.instance_count):
        var local_pose := cell.multimesh.get_instance_transform(index)
        var position := cell.position + local_pose.origin
        var clearance := absf(position.z - 128.0)
        if clearance < 6.0 * 0.5 + Groundcover.MIN_ROAD_CLEARANCE_M - 0.001:
            _fail("groundcover anchor entered the road clearance envelope")
            return
        if not is_equal_approx(position.y, 5.015):
            _fail("groundcover did not use registered terrain height")
            return
        if position.z > 128.0:
            positive_side += 1
        else:
            negative_side += 1
    if positive_side <= 0 or negative_side <= 0:
        _fail("groundcover must populate both sides of the road")
        return
    if fake_terrain.calls != anchors:
        _fail("terrain sampling count mismatch: %d != %d" % [fake_terrain.calls, anchors])
        return
    if tile_root.find_children("*", "CollisionShape3D", true, false).size() != 0:
        _fail("visual groundcover unexpectedly created collision")
        return

    tile_root.free()
    helper.free()
    fake_roads.free()
    fake_terrain.free()
    print("YARDMAN_NEAR_FIELD_GROUNDCOVER_RUNTIME_TEST PASS anchors=38 cells=1 road_clearance=1 terrain=1 multimesh=1 shadows=0 collision=0")
    quit(0)
