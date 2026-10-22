extends SceneTree

const Culverts = preload("res://scripts/culvert_structure_runtime.gd")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("CULVERT_STRUCTURE_RUNTIME_TEST: " + message)
    quit(1)

func _run() -> void:
    var crossing := {
        "x": 102.0,
        "z": 205.0,
        "status": "approved",
        "kind": "culvert",
        "road_width_m": 8.0,
        "road_edge_id": "road-17",
    }
    var source_copy := crossing.duplicate(true)
    var a := Vector3(102.0, 11.0, 190.0)
    var b := Vector3(102.0, 13.0, 220.0)
    if not Culverts.crossing_eligible(crossing):
        _fail("approved culvert was rejected")
        return
    var plan := Culverts.culvert_plan(crossing, a, b, 3.0)
    if plan.is_empty():
        _fail("valid approved culvert produced no structure plan")
        return
    if crossing != source_copy:
        _fail("planner mutated reconciled crossing truth")
        return
    var mouths: Array = plan.get("mouths", [])
    if mouths.size() != 2:
        _fail("culvert did not produce two road-edge mouths")
        return
    var crossing_point: Vector2 = plan.get("crossing", Vector2(INF, INF))
    var expected_offset := 8.0 * 0.5 + Culverts.ROAD_EDGE_MARGIN_M
    for mouth: Dictionary in mouths:
        var center: Vector3 = mouth.get("center", Vector3(INF, INF, INF))
        var horizontal := Vector2(center.x, center.z)
        if absf(horizontal.distance_to(crossing_point) - expected_offset) > 0.001:
            _fail("culvert mouth is not anchored to exact compiled road edge")
            return
        if not is_finite(center.y):
            _fail("culvert mouth elevation is invalid")
            return
    if absf(float(plan.get("road_width_m", 0.0)) - 8.0) > 0.001:
        _fail("exact reconciled road width was not preserved")
        return
    if float(plan.get("headwall_width_m", 0.0)) <= 3.0:
        _fail("headwall does not clear compiled channel width")
        return

    var bridge := crossing.duplicate(true)
    bridge.kind = "bridge"
    if Culverts.crossing_eligible(bridge) or not Culverts.culvert_plan(bridge, a, b, 3.0).is_empty():
        _fail("approved bridge entered culvert structure path")
        return
    var ford := crossing.duplicate(true)
    ford.kind = "ford"
    if Culverts.crossing_eligible(ford):
        _fail("approved ford entered culvert structure path")
        return
    var unresolved := crossing.duplicate(true)
    unresolved.status = "unresolved"
    if Culverts.crossing_eligible(unresolved):
        _fail("unresolved crossing entered culvert structure path")
        return
    var conflict := crossing.duplicate(true)
    conflict.status = "conflict"
    if Culverts.crossing_eligible(conflict):
        _fail("conflicting crossing entered culvert structure path")
        return
    var missing_width := crossing.duplicate(true)
    missing_width.erase("road_width_m")
    if Culverts.crossing_eligible(missing_width):
        _fail("culvert without exact road width was accepted")
        return
    var off_segment := crossing.duplicate(true)
    off_segment.x = 110.0
    if not Culverts.culvert_plan(off_segment, a, b, 3.0).is_empty():
        _fail("crossing outside compiled water segment tolerance was accepted")
        return

    var contract := Culverts.runtime_contract()
    if int(contract.get("format_version", 0)) != 2 or str(contract.get("status", "")) != "approved" or str(contract.get("kind", "")) != "culvert":
        _fail("v2 approved-culvert runtime contract drifted")
        return
    if int(contract.get("max_culverts", 999)) > 32 or float(contract.get("visibility_m", 999.0)) > 240.0:
        _fail("culvert runtime exceeded bounded Android presentation budget")
        return
    if str(contract.get("material_asset", "")) != "building_concrete.png":
        _fail("recovered concrete material binding drifted")
        return
    if bool(contract.get("terrain_mutation", true)) or bool(contract.get("water_mutation", true)) \
            or bool(contract.get("road_mutation", true)) or bool(contract.get("collision", true)) \
            or bool(contract.get("shadows", true)):
        _fail("culvert presentation gained world/physics authority")
        return

    print("YARDMAN_CULVERT_STRUCTURE_RUNTIME_TEST PASS approved=1 mouths=2 road_width_exact=1 channel_clear=1 bridge_rejected=1 ford_rejected=1 unresolved_rejected=1 conflict_rejected=1 off_segment_rejected=1 source_unchanged=1 terrain_mutation=0 water_mutation=0 road_mutation=0 collision=0 shadows=0")
    quit(0)
