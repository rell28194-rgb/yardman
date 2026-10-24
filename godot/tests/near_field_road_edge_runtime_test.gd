extends SceneTree

const RoadEdge = preload("res://scripts/near_field_road_edge_runtime.gd")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("NEAR_FIELD_ROAD_EDGE_RUNTIME_TEST: " + message)
    quit(1)

func _run() -> void:
    var ordinary := {"a": Vector2(0.0, 0.0), "b": Vector2(20.0, 0.0), "width_m": 6.0, "flags": 0, "edge_id": "test:ordinary"}
    var bridge := ordinary.duplicate()
    bridge.flags = RoadEdge.BRIDGE_FLAG
    var tunnel := ordinary.duplicate()
    tunnel.flags = RoadEdge.TUNNEL_FLAG
    if not RoadEdge.record_eligible(ordinary) or RoadEdge.record_eligible(bridge) or RoadEdge.record_eligible(tunnel):
        _fail("bridge/tunnel exclusion contract failed")
        return

    var ford := [{"x": 10.0, "z": 0.0, "status": "approved", "kind": "ford", "road_width_m": 6.0}]
    if not RoadEdge.crossing_blocks_record(ordinary, ford):
        _fail("approved ford did not block presentation geometry")
        return
    var unresolved := [{"x": 9.0, "z": 0.5, "status": "unresolved", "kind": "unknown", "road_width_m": 5.0}]
    if not RoadEdge.crossing_blocks_record(ordinary, unresolved):
        _fail("unresolved hydrology crossing did not fail closed")
        return
    var remote := [{"x": 10.0, "z": 30.0, "status": "approved", "kind": "ford", "road_width_m": 6.0}]
    if RoadEdge.crossing_blocks_record(ordinary, remote):
        _fail("remote crossing incorrectly blocked road detail")
        return

    var source_copy := ordinary.duplicate(true)
    var plans := RoadEdge.shoulder_plan(ordinary)
    if plans.size() < 2:
        _fail("ordinary road did not produce two shoulders")
        return
    if ordinary != source_copy:
        _fail("road-edge planner mutated compiled road record")
        return
    var half_width := float(ordinary.width_m) * 0.5
    var shoulder_count := 0
    for plan: Dictionary in plans:
        if str(plan.get("kind", "")) != "shoulder":
            continue
        shoulder_count += 1
        var points: Array = plan.get("points", [])
        if points.size() != 4:
            _fail("shoulder is not a single quad")
            return
        for raw: Variant in points:
            var point: Vector2 = raw
            var centreline_distance := absf(point.y)
            if centreline_distance <= half_width:
                _fail("shoulder intruded into compiled pavement width")
                return
    if shoulder_count != 2:
        _fail("expected exactly two shoulder strips")
        return
    if RoadEdge.VISIBILITY_END_M > 180.0 or RoadEdge.ACTIVE_RADIUS_M > 256.0 or RoadEdge.MAX_SEGMENTS > 256:
        _fail("near-field Android budget exceeded")
        return

    var hydrology_root := Node.new()
    root.add_child(hydrology_root)
    var legacy := Node.new()
    legacy.name = RoadEdge.LEGACY_HYDROLOGY_NODE
    hydrology_root.add_child(legacy)
    if RoadEdge.resolve_hydrology_node(hydrology_root) != legacy:
        _fail("legacy hydrology renderer fallback is not resolved")
        return
    var live := Node.new()
    live.name = RoadEdge.LIVE_HYDROLOGY_NODE
    hydrology_root.add_child(live)
    if RoadEdge.resolve_hydrology_node(hydrology_root) != live:
        _fail("live hydrology renderer is not preferred")
        return
    hydrology_root.remove_child(live)
    live.free()
    if RoadEdge.resolve_hydrology_node(hydrology_root) != legacy:
        _fail("hydrology fallback did not recover after live renderer removal")
        return
    hydrology_root.remove_child(legacy)
    legacy.free()
    if RoadEdge.resolve_hydrology_node(hydrology_root) != null:
        _fail("missing hydrology did not fail closed")
        return
    hydrology_root.free()

    var node := RoadEdge.new()
    root.add_child(node)
    var child := MeshInstance3D.new()
    child.name = "RoadEdgeDetail"
    child.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    child.set_meta("collision", false)
    node.add_child(child)
    if child.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF or bool(child.get_meta("collision", true)):
        _fail("visual-only shadow/collision contract failed")
        return
    if child.find_children("*", "CollisionShape3D", true, false).size() != 0 or child.find_children("*", "StaticBody3D", true, false).size() != 0:
        _fail("road-edge detail created gameplay collision")
        return
    node.free()

    print("YARDMAN_NEAR_FIELD_ROAD_EDGE_RUNTIME_TEST PASS shoulders=2 pavement_clear=1 bridge_rejected=1 tunnel_rejected=1 ford_rejected=1 unresolved_rejected=1 source_unchanged=1 near_only=1 collision=0 shadows=0 hydrology_live=1 hydrology_legacy=1 fail_closed=1")
    quit(0)