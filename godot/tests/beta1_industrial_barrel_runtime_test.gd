extends SceneTree

const Barrels = preload("res://scripts/beta1_industrial_barrel_runtime.gd")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("BETA1_INDUSTRIAL_BARREL_RUNTIME_TEST: " + message)
    quit(1)

func _record(building_type: String, part := false) -> Array:
    return ["osm/test", 6.0, 3, 2, 6.0,
        [[[0.0, 0.0, 0.0], [8.0, 0.0, 0.0], [8.0, 0.0, 8.0], [0.0, 0.0, 8.0]]],
        [], [], {"building_type": building_type, "building_part": part}]

func _run() -> void:
    var industrial := _record("industrial")
    var industrial_copy := industrial.duplicate(true)
    if not Barrels.is_industrial_record(industrial):
        _fail("industrial source building rejected")
        return
    if not Barrels.is_industrial_record(_record("warehouse")):
        _fail("warehouse source building rejected")
        return
    if Barrels.is_industrial_record(_record("house")) or Barrels.is_industrial_record(_record("commercial")):
        _fail("non-industrial source type accepted")
        return
    if Barrels.is_industrial_record(_record("industrial", true)):
        _fail("building:part record accepted as standalone barrel host")
        return

    var ring: Array = industrial[5][0]
    var edge := Barrels.edge_from_ring(ring, 0)
    if edge.is_empty() or absf(float(edge.length_m) - 8.0) > 0.001:
        _fail("source footprint edge failed")
        return
    # Ring is CCW; first edge's outward normal points toward -Z.
    var road := {"point": Vector2(4.0, -6.0), "width_m": 5.0, "flags": 0}
    var plan := Barrels.plan_barrel(edge, road, Vector2.ZERO, 42)
    if plan.is_empty():
        _fail("valid industrial frontage produced no barrel plan")
        return
    var canonical: Vector2 = plan.get("canonical", Vector2(INF, INF))
    if not canonical.is_finite() or canonical.y >= 0.0:
        _fail("barrel was not placed outside the industrial frontage toward road access")
        return
    if float(plan.get("pavement_clearance_m", 0.0)) < 0.85:
        _fail("barrel encroached on compiled pavement")
        return

    var bridge := road.duplicate(true)
    bridge["flags"] = 2
    if not Barrels.plan_barrel(edge, bridge, Vector2.ZERO, 42).is_empty():
        _fail("bridge frontage received barrel")
        return
    var tunnel := road.duplicate(true)
    tunnel["flags"] = 4
    if not Barrels.plan_barrel(edge, tunnel, Vector2.ZERO, 42).is_empty():
        _fail("tunnel frontage received barrel")
        return
    var close_road := road.duplicate(true)
    close_road["point"] = Vector2(4.0, -3.0)
    close_road["width_m"] = 5.0
    if not Barrels.plan_barrel(edge, close_road, Vector2.ZERO, 42).is_empty():
        _fail("unsafe pavement clearance accepted")
        return
    var rear_road := road.duplicate(true)
    rear_road["point"] = Vector2(4.0, 8.0)
    if not Barrels.plan_barrel(edge, rear_road, Vector2.ZERO, 42).is_empty():
        _fail("rear-facing road accepted")
        return
    if industrial != industrial_copy:
        _fail("planner mutated source building record")
        return

    var contract := Barrels.asset_contract()
    if str(contract.get("file", "")) != "settlement_industrial_barrel.glb":
        _fail("private barrel filename drifted")
        return
    var types: Array = contract.get("accepted_building_types", [])
    if types != ["industrial", "warehouse"]:
        _fail("building-type gate drifted")
        return
    if int(contract.get("max_barrels_per_cell", 999)) > 6 or float(contract.get("visibility_m", 999.0)) > 100.0:
        _fail("near-field Android budget expanded")
        return
    if bool(contract.get("collision", true)) or bool(contract.get("shadows", true)) \
            or bool(contract.get("residential_placement", true)) or bool(contract.get("commercial_placement", true)):
        _fail("industrial prop gained unsafe authority")
        return
    if not bool(contract.get("source_scale_preserved", false)) or not bool(contract.get("asset_absent_fallback", false)):
        _fail("source-scale/fallback contract missing")
        return

    print("YARDMAN_BETA1_INDUSTRIAL_BARREL_RUNTIME_TEST PASS industrial=1 warehouse=1 residential=0 commercial=0 parts=0 pavement_clear=1 bridge=0 tunnel=0 source_unchanged=1 near_only=1 collision=0 shadows=0")
    quit(0)
