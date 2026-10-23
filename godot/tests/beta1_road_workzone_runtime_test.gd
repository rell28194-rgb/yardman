extends SceneTree

const Workzone = preload("res://scripts/beta1_road_workzone_runtime.gd")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("BETA1_ROAD_WORKZONE_RUNTIME_TEST: " + message)
    quit(1)

func _count_kind(plans: Array[Dictionary], kind: String) -> int:
    var count := 0
    for plan: Dictionary in plans:
        if str(plan.get("kind", "")) == kind:
            count += 1
    return count

func _run() -> void:
    var short_record := {
        "id": "w100:0:0",
        "source_way": "w100",
        "construction": "primary",
        "a": [100.0, 12.0, 200.0],
        "b": [112.0, 14.0, 200.0],
    }
    var short_copy := short_record.duplicate(true)
    var short_plans := Workzone.plans_for_record(short_record, Vector2.ZERO, 96)
    if short_plans.size() < 2 or _count_kind(short_plans, "cone") != short_plans.size():
        _fail("short sourced work zone did not stay cone-only")
        return
    if short_record != short_copy:
        _fail("planner mutated source work-zone record")
        return

    var long_record := {
        "id": "w200:0:0",
        "source_way": "w200",
        "construction": "secondary",
        "a": [4098.0, 20.0, 8196.0],
        "b": [4148.0, 25.0, 8196.0],
    }
    var tile_origin := Vector2(4096.0, 8192.0)
    var long_plans := Workzone.plans_for_record(long_record, tile_origin, 96)
    if _count_kind(long_plans, "cone") < 5 or _count_kind(long_plans, "barrier") < 1 \
            or _count_kind(long_plans, "fence") < 1:
        _fail("long sourced work zone did not expose all recovered prop families")
        return
    for plan: Dictionary in long_plans:
        var pose: Transform3D = plan.get("transform", Transform3D.IDENTITY)
        var canonical: Vector3 = plan.get("canonical", Vector3.INF)
        if not pose.origin.is_finite() or not canonical.is_finite():
            _fail("planner emitted non-finite placement")
            return
        if pose.origin.x < -10.0 or pose.origin.x > 70.0 or pose.origin.z < -10.0 or pose.origin.z > 20.0:
            _fail("tile-local work-zone placement escaped its source tile envelope")
            return
        if not bool(plan.get("source_only", false)):
            _fail("placement lost source-only marker")
            return

    var capped := Workzone.plans_for_record(long_record, tile_origin, 4)
    if capped.size() != 4:
        _fail("per-record planner did not honor hard prop budget")
        return
    if not Workzone.plans_for_record({}, Vector2.ZERO, 96).is_empty():
        _fail("malformed unsourced record produced props")
        return

    var contract := Workzone.asset_contract()
    var files: Dictionary = contract.get("files", {})
    if str(files.get("cone", "")) != "road_repair_cone.glb" \
            or str(files.get("barrier", "")) != "road_concrete_barrier.glb" \
            or str(files.get("fence", "")) != "road_portable_fence.glb":
        _fail("recovered construction prop filenames drifted")
        return
    if str(contract.get("source", "")) != "OSM highway=construction only" \
            or str(contract.get("work_zone_file", "")) != "res://data/roads/work_zones.json":
        _fail("authoritative work-zone source contract drifted")
        return
    if bool(contract.get("routing", true)) or bool(contract.get("collision", true)) \
            or bool(contract.get("shadows", true)) or bool(contract.get("ordinary_road_placement", true)):
        _fail("work-zone props gained routing/collision/shadow/ordinary-road authority")
        return
    if int(contract.get("max_source_segments_per_tile", 999)) > 24 \
            or int(contract.get("max_props_per_tile", 999)) > 96 \
            or float(contract.get("visibility_m", 999.0)) > 160.0:
        _fail("work-zone presentation exceeded bounded Android budget")
        return
    if not bool(contract.get("asset_absent_fallback", false)):
        _fail("private-asset-absent fallback is not explicit")
        return

    print("YARDMAN_BETA1_ROAD_WORKZONE_RUNTIME_TEST PASS cone=1 barrier=1 fence=1 source_only=1 ordinary_roads=0 routing=0 collision=0 shadows=0 budget=1")
    quit(0)
