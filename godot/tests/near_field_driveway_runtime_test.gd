extends SceneTree

const Driveways = preload("res://scripts/near_field_driveway_runtime.gd")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("NEAR_FIELD_DRIVEWAY_RUNTIME_TEST: " + message)
    quit(1)

func _run() -> void:
    var edge := {
        "mid": Vector3(0.0, 0.0, 0.0),
        "normal": Vector3.BACK,
        "length_m": 8.0,
    }
    var edge_copy := edge.duplicate(true)
    var road := {
        "point": Vector2(0.0, 6.0),
        "width_m": 4.0,
        "flags": 0,
    }
    var road_copy := road.duplicate(true)

    var plan := Driveways.plan_driveway(edge, road, Vector2.ZERO, 16)
    if plan.is_empty():
        _fail("valid paved road-facing frontage produced no driveway")
        return
    var corners: Array = plan.get("corners", [])
    if corners.size() != 4:
        _fail("driveway plan did not preserve a four-corner strip")
        return
    for raw: Variant in corners:
        if not raw is Vector2 or not (raw as Vector2).is_finite():
            _fail("driveway corner is invalid")
            return
    var center: Vector2 = plan.get("center", Vector2(INF, INF))
    if not center.is_finite() or center.y <= 0.0 or center.y >= 6.0:
        _fail("driveway center does not lie between frontage and road")
        return
    var width_m := float(plan.get("width_m", 0.0))
    var length_m := float(plan.get("length_m", 0.0))
    if width_m < 2.4 or width_m > 3.25 or length_m < 1.8 or length_m > Driveways.MAX_CLEARANCE_M + 1.5:
        _fail("driveway dimensions escaped bounded contract")
        return

    var unpaved := road.duplicate(true)
    unpaved["flags"] = 8
    if not Driveways.plan_driveway(edge, unpaved, Vector2.ZERO, 16).is_empty():
        _fail("unpaved road received asphalt driveway inference")
        return
    var bridge := road.duplicate(true)
    bridge["flags"] = 2
    if not Driveways.plan_driveway(edge, bridge, Vector2.ZERO, 16).is_empty():
        _fail("bridge frontage received driveway inference")
        return
    var tunnel := road.duplicate(true)
    tunnel["flags"] = 4
    if not Driveways.plan_driveway(edge, tunnel, Vector2.ZERO, 16).is_empty():
        _fail("tunnel frontage received driveway inference")
        return
    var too_close := road.duplicate(true)
    too_close["point"] = Vector2(0.0, 4.0)
    if not Driveways.plan_driveway(edge, too_close, Vector2.ZERO, 16).is_empty():
        _fail("unsafe short clearance accepted")
        return
    var too_far := road.duplicate(true)
    too_far["point"] = Vector2(0.0, 8.0)
    if not Driveways.plan_driveway(edge, too_far, Vector2.ZERO, 16).is_empty():
        _fail("frontage beyond safe boundary threshold accepted")
        return
    var rear := road.duplicate(true)
    rear["point"] = Vector2(0.0, -6.0)
    if not Driveways.plan_driveway(edge, rear, Vector2.ZERO, 16).is_empty():
        _fail("rear-facing road received driveway inference")
        return
    if not Driveways.plan_driveway(edge, road, Vector2.ZERO, 17).is_empty():
        _fail("density gate drifted from deterministic quarter-sampling")
        return
    if edge != edge_copy or road != road_copy:
        _fail("planner mutated source edge or road record")
        return

    var contract := Driveways.contract()
    if str(contract.get("surface_asset", "")) != "road_asphalt_detail.png":
        _fail("driveway surface asset drifted")
        return
    if int(contract.get("max_driveways_per_cell", 999)) > 12 or float(contract.get("visibility_m", 999.0)) > 140.0:
        _fail("driveway runtime exceeded near-field Android budget")
        return
    if float(contract.get("max_clearance_m", 999.0)) >= float(contract.get("frontage_boundary_threshold_m", 0.0)):
        _fail("driveway inference no longer fails closed before frontage boundary details")
        return
    if not bool(contract.get("shared_frontage_seed", false)) \
            or not bool(contract.get("bridge_rejected", false)) \
            or not bool(contract.get("tunnel_rejected", false)) \
            or not bool(contract.get("unpaved_rejected", false)):
        _fail("driveway exclusion contract drifted")
        return
    if bool(contract.get("collision", true)) or bool(contract.get("terrain_mutation", true)) \
            or bool(contract.get("navigation", true)):
        _fail("driveway presentation gained physics/terrain/navigation authority")
        return

    print("YARDMAN_NEAR_FIELD_DRIVEWAY_RUNTIME_TEST PASS paved=1 unpaved_rejected=1 bridge_rejected=1 tunnel_rejected=1 clearance_gated=1 rear_rejected=1 density_gated=1 source_unchanged=1 near_only=1 collision=0 terrain_mutation=0 navigation=0")
    quit(0)
