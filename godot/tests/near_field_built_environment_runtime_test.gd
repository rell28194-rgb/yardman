extends SceneTree

const BuiltEnvironment = preload("res://scripts/near_field_built_environment_runtime.gd")
const Driveways = preload("res://scripts/near_field_driveway_runtime.gd")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("NEAR_FIELD_BUILT_ENVIRONMENT_RUNTIME_TEST: " + message)
    quit(1)

func _run() -> void:
    var vertices := PackedVector3Array([
        Vector3(-4.0, 0.0, 0.0), Vector3(-4.0, 3.0, 0.0),
        Vector3(4.0, 0.0, 0.0), Vector3(4.0, 3.0, 0.0),
        Vector3(-4.0, 0.0, -4.0), Vector3(-4.0, 3.0, -4.0),
        Vector3(4.0, 0.0, -4.0), Vector3(4.0, 3.0, -4.0),
    ])
    var normals := PackedVector3Array([
        Vector3.BACK, Vector3.BACK, Vector3.BACK, Vector3.BACK,
        Vector3.FORWARD, Vector3.FORWARD, Vector3.FORWARD, Vector3.FORWARD,
    ])
    var source_copy := vertices.duplicate()
    # Road edge clearance is 5 m: driveway-eligible, but still below the 5.5 m
    # boundary-wall/fence inference threshold.
    var road := {
        "a": Vector2(-20.0, 8.0),
        "b": Vector2(20.0, 8.0),
        "width_m": 6.0,
        "flags": 0,
    }

    var front := BuiltEnvironment._edge_from_wall(vertices, normals, 0)
    if front.is_empty():
        _fail("front wall was rejected")
        return
    var front_road := BuiltEnvironment._nearest_road(Vector2(0.0, 0.0), [road])
    var front_plan := BuiltEnvironment._plan_front_edge(front, front_road, Vector2.ZERO, 10)
    if front_plan.is_empty():
        _fail("road-facing wall produced no near-field detail")
        return

    var driveway_source := front.duplicate(true)
    var driveway_road := front_road.duplicate(true)
    var driveway := Driveways.plan_driveway(front, front_road, Vector2.ZERO, 12)
    if driveway.is_empty():
        _fail("eligible paved road-facing building did not produce a driveway")
        return
    var corners: Array = driveway.get("corners", [])
    if corners.size() != 4 or float(driveway.get("width_m", 0.0)) < 2.4 \
            or float(driveway.get("length_m", 0.0)) < 1.8:
        _fail("driveway geometry contract is invalid")
        return
    var bridge_road := front_road.duplicate(true)
    bridge_road["flags"] = 2
    if not Driveways.plan_driveway(front, bridge_road, Vector2.ZERO, 12).is_empty():
        _fail("bridge frontage received an inferred driveway")
        return
    var tunnel_road := front_road.duplicate(true)
    tunnel_road["flags"] = 4
    if not Driveways.plan_driveway(front, tunnel_road, Vector2.ZERO, 12).is_empty():
        _fail("tunnel frontage received an inferred driveway")
        return
    var unpaved_road := front_road.duplicate(true)
    unpaved_road["flags"] = 8
    if not Driveways.plan_driveway(front, unpaved_road, Vector2.ZERO, 12).is_empty():
        _fail("unpaved frontage received a fake asphalt driveway")
        return
    if not Driveways.plan_driveway(front, front_road, Vector2.ZERO, 13).is_empty():
        _fail("driveway density gate stopped being deterministic")
        return
    var distant_boundary_road := {
        "a": Vector2(-20.0, 8.6),
        "b": Vector2(20.0, 8.6),
        "width_m": 6.0,
        "flags": 0,
    }
    var distant_front_road := BuiltEnvironment._nearest_road(Vector2(0.0, 0.0), [distant_boundary_road])
    if not Driveways.plan_driveway(front, distant_front_road, Vector2.ZERO, 12).is_empty():
        _fail("driveway crossed into the frontage wall/fence clearance band")
        return
    if front != driveway_source or front_road != driveway_road:
        _fail("driveway planner mutated source building/road records")
        return
    var driveway_contract := Driveways.contract()
    if str(driveway_contract.get("surface_asset", "")) != "road_asphalt_detail.png" \
            or int(driveway_contract.get("max_driveways_per_cell", 999)) > 16 \
            or float(driveway_contract.get("visibility_m", 999.0)) > 150.0:
        _fail("driveway asset/budget contract drifted")
        return
    if float(driveway_contract.get("max_clearance_m", 99.0)) >= float(driveway_contract.get("frontage_boundary_threshold_m", 0.0)) \
            or not bool(driveway_contract.get("shared_frontage_seed", false)):
        _fail("driveway/frontage coordination contract drifted")
        return
    if bool(driveway_contract.get("collision", true)) \
            or bool(driveway_contract.get("terrain_mutation", true)) \
            or bool(driveway_contract.get("navigation", true)):
        _fail("driveway presentation gained gameplay/terrain authority")
        return

    var rear := BuiltEnvironment._edge_from_wall(vertices, normals, 4)
    var rear_road := BuiltEnvironment._nearest_road(Vector2(0.0, -4.0), [road])
    var rear_plan := BuiltEnvironment._plan_front_edge(rear, rear_road, Vector2.ZERO, 10)
    if not rear_plan.is_empty():
        _fail("rear wall was decorated even though its outward normal faces away from the road")
        return

    if vertices != source_copy:
        _fail("presentation planner mutated source building geometry")
        return
    if BuiltEnvironment.DETAIL_DISTANCE_M > 120.0 or BuiltEnvironment.ACTIVE_RADIUS_M > 256.0:
        _fail("detail layer exceeded near-field bounds")
        return
    if front_plan.size() > BuiltEnvironment.MAX_DETAILS_PER_CELL:
        _fail("detail plan exceeded per-cell cap")
        return

    var groups: Dictionary = {}
    var grounded := false
    for plan: Dictionary in front_plan:
        groups[str(plan.get("group", ""))] = true
        grounded = grounded or bool(plan.get("grounded", false))
    if groups.size() != 3 or not groups.has("masonry") or not groups.has("metal") or not groups.has("post"):
        _fail("expected deterministic masonry/metal/post batching, got %s" % str(groups.keys()))
        return
    if not grounded:
        _fail("roadside infrastructure did not retain terrain-grounding contract")
        return

    var helper := BuiltEnvironment.new()
    var cell_root := Node3D.new()
    root.add_child(cell_root)
    helper._attach_plan(cell_root, front_plan, 1)
    var detail := cell_root.get_node_or_null("NearFieldBuiltEnvironment") as Node3D
    if detail == null:
        _fail("detail root missing")
        return
    if not bool(detail.get_meta("presentation_inference", false)) or bool(detail.get_meta("collision", true)):
        _fail("presentation/collision metadata contract failed")
        return
    if detail.get_child_count() != groups.size():
        _fail("details did not collapse to one MultiMesh per material group")
        return
    for child in detail.get_children():
        var instance := child as MultiMeshInstance3D
        if instance == null or instance.multimesh == null:
            _fail("detail batch is not a MultiMesh")
            return
        if instance.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
            _fail("near-field detail unexpectedly casts shadows")
            return
        if not is_equal_approx(instance.visibility_range_end, BuiltEnvironment.DETAIL_DISTANCE_M):
            _fail("detail visibility range drifted")
            return
    if detail.find_children("*", "CollisionShape3D", true, false).size() != 0 or detail.find_children("*", "StaticBody3D", true, false).size() != 0:
        _fail("presentation detail created gameplay collision")
        return

    cell_root.free()
    helper.free()
    print("YARDMAN_NEAR_FIELD_BUILT_ENVIRONMENT_TEST PASS front=1 rear_rejected=1 groups=3 source_unchanged=1 near_only=1 collision=0")
    quit(0)
