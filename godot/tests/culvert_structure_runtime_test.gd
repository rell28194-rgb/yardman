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
        "road_edge": "road-17",
    }
    var source_copy := crossing.duplicate(true)
    var water_a := Vector3(102.0, 11.0, 190.0)
    var water_b := Vector3(102.0, 13.0, 220.0)
    var road := {
        "a": Vector2(90.0, 205.0),
        "b": Vector2(114.0, 205.0),
        "width_m": 8.0,
        "edge_id": "road-17",
        "flags": 0,
    }
    var road_copy := road.duplicate(true)
    if not Culverts.crossing_eligible(crossing):
        _fail("approved v2 culvert was rejected")
        return
    var selected := Culverts.select_road_record(crossing, [
        {"a": Vector2(90.0, 206.0), "b": Vector2(114.0, 206.0), "width_m": 8.0, "edge_id": "wrong-edge"},
        road,
    ])
    if selected.is_empty() or str(selected.get("edge_id", "")) != "road-17":
        _fail("exact compiled road edge was not resolved")
        return
    var plan := Culverts.culvert_plan(crossing, water_a, water_b, 3.0, selected)
    if plan.is_empty():
        _fail("valid approved culvert produced no structure plan")
        return
    if crossing != source_copy or road != road_copy:
        _fail("planner/resolver mutated source crossing or road truth")
        return
    var mouths: Array = plan.get("mouths", [])
    if mouths.size() != 2:
        _fail("culvert did not produce two road-edge mouths")
        return
    var crossing_point: Vector2 = plan.get("crossing", Vector2(INF, INF))
    var expected_edge_distance := 8.0 * 0.5 + Culverts.ROAD_EDGE_MARGIN_M
    var road_normal: Vector2 = plan.get("road_normal", Vector2.ZERO)
    for mouth: Dictionary in mouths:
        var center: Vector3 = mouth.get("center", Vector3(INF, INF, INF))
        var horizontal := Vector2(center.x, center.z)
        if absf(horizontal.distance_to(crossing_point) - expected_edge_distance) > 0.001:
            _fail("perpendicular culvert mouth offset drifted")
            return
        if absf(absf((horizontal - crossing_point).dot(road_normal)) - expected_edge_distance) > 0.001:
            _fail("perpendicular culvert mouth is not on exact road edge plane")
            return
        if not is_finite(center.y):
            _fail("culvert mouth elevation is invalid")
            return
    if absf(float(plan.get("road_width_m", 0.0)) - 8.0) > 0.001 or absf(float(plan.get("oblique_factor", 0.0)) - 1.0) > 0.001:
        _fail("exact road width/perpendicular factor was not preserved")
        return
    var wall_width := float(plan.get("headwall_width_m", 0.0))
    var wall_height := float(plan.get("headwall_height_m", 0.0))
    var opening_width := float(plan.get("opening_width_m", 0.0))
    var opening_height := float(plan.get("opening_height_m", 0.0))
    if wall_width <= 3.0:
        _fail("headwall does not clear compiled channel width")
        return
    if opening_width <= 0.65 or opening_width >= wall_width or opening_height <= 0.75 or opening_height >= wall_height:
        _fail("headwall does not preserve a real open water aperture")
        return

    # 45-degree road crossing: the water path through the road ribbon is longer
    # by 1/cos(45°). Mouths still need to land on the road-edge planes rather
    # than at a naive width/2 distance along the channel.
    var oblique_road := {
        "a": Vector2(92.0, 195.0),
        "b": Vector2(112.0, 215.0),
        "width_m": 8.0,
        "edge_id": "road-17",
    }
    var oblique_selected := Culverts.select_road_record(crossing, [oblique_road])
    var oblique := Culverts.culvert_plan(crossing, water_a, water_b, 3.0, oblique_selected)
    if oblique.is_empty():
        _fail("valid 45-degree culvert was rejected")
        return
    var expected_factor := sqrt(2.0)
    if absf(float(oblique.get("oblique_factor", 0.0)) - expected_factor) > 0.002:
        _fail("45-degree crossing did not expand mouth offset by secant factor")
        return
    var oblique_normal: Vector2 = oblique.get("road_normal", Vector2.ZERO)
    for mouth: Dictionary in oblique.get("mouths", []):
        var center: Vector3 = mouth.get("center", Vector3(INF, INF, INF))
        var horizontal := Vector2(center.x, center.z)
        if absf(absf((horizontal - crossing_point).dot(oblique_normal)) - expected_edge_distance) > 0.002:
            _fail("oblique culvert mouth missed exact road edge plane")
            return
    if float(oblique.get("mouth_offset_m", 0.0)) <= expected_edge_distance:
        _fail("oblique crossing retained naive width/2 channel offset")
        return

    var parallel_road := {
        "a": Vector2(102.0, 190.0), "b": Vector2(102.0, 220.0),
        "width_m": 8.0, "edge_id": "road-17",
    }
    var parallel_selected := Culverts.select_road_record(crossing, [parallel_road])
    if parallel_selected.is_empty() or not Culverts.culvert_plan(crossing, water_a, water_b, 3.0, parallel_selected).is_empty():
        _fail("near-parallel road/channel geometry did not fail closed")
        return

    var wrong_edge := road.duplicate(true)
    wrong_edge["edge_id"] = "road-99"
    if not Culverts.select_road_record(crossing, [wrong_edge]).is_empty():
        _fail("wrong road edge ID was accepted")
        return
    var wrong_width := road.duplicate(true)
    wrong_width["width_m"] = 7.5
    if not Culverts.select_road_record(crossing, [wrong_width]).is_empty():
        _fail("road width inconsistent with reconciled v2 truth was accepted")
        return
    var off_center := road.duplicate(true)
    off_center["a"] = Vector2(90.0, 206.0)
    off_center["b"] = Vector2(114.0, 206.0)
    if not Culverts.select_road_record(crossing, [off_center]).is_empty():
        _fail("road segment outside centerline reconciliation tolerance was accepted")
        return

    var bridge := crossing.duplicate(true)
    bridge["kind"] = "bridge"
    if Culverts.crossing_eligible(bridge) or not Culverts.culvert_plan(bridge, water_a, water_b, 3.0, road).is_empty():
        _fail("approved bridge entered culvert structure path")
        return
    var ford := crossing.duplicate(true)
    ford["kind"] = "ford"
    if Culverts.crossing_eligible(ford):
        _fail("approved ford entered culvert structure path")
        return
    var unresolved := crossing.duplicate(true)
    unresolved["status"] = "unresolved"
    if Culverts.crossing_eligible(unresolved):
        _fail("unresolved crossing entered culvert structure path")
        return
    var conflict := crossing.duplicate(true)
    conflict["status"] = "conflict"
    if Culverts.crossing_eligible(conflict):
        _fail("conflicting crossing entered culvert structure path")
        return
    var missing_width := crossing.duplicate(true)
    missing_width.erase("road_width_m")
    if Culverts.crossing_eligible(missing_width):
        _fail("culvert without exact road width was accepted")
        return
    var missing_edge := crossing.duplicate(true)
    missing_edge.erase("road_edge")
    if Culverts.crossing_eligible(missing_edge):
        _fail("culvert without exact road edge ID was accepted")
        return
    var off_water_segment := crossing.duplicate(true)
    off_water_segment["x"] = 110.0
    var off_water_road := road.duplicate(true)
    off_water_road["a"] = Vector2(90.0, 205.0)
    off_water_road["b"] = Vector2(114.0, 205.0)
    if not Culverts.culvert_plan(off_water_segment, water_a, water_b, 3.0, off_water_road).is_empty():
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
    if not bool(contract.get("open_aperture", false)) or not bool(contract.get("exact_road_edge_required", false)) \
            or not bool(contract.get("oblique_road_edges", false)):
        _fail("runtime lost open/exact/oblique crossing contract")
        return
    if float(contract.get("max_oblique_factor", 99.0)) > 4.0 or float(contract.get("road_center_tolerance_m", 99.0)) > 0.35 \
            or float(contract.get("road_width_tolerance_m", 99.0)) > 0.05:
        _fail("road reconciliation tolerances exceeded bounded fail-closed contract")
        return
    if bool(contract.get("terrain_mutation", true)) or bool(contract.get("water_mutation", true)) \
            or bool(contract.get("road_mutation", true)) or bool(contract.get("collision", true)) \
            or bool(contract.get("shadows", true)):
        _fail("culvert presentation gained world/physics authority")
        return

    print("YARDMAN_CULVERT_STRUCTURE_RUNTIME_TEST PASS approved=1 mouths=2 road_width_exact=1 channel_clear=1 bridge_rejected=1 ford_rejected=1 unresolved_rejected=1 conflict_rejected=1 off_segment_rejected=1 source_unchanged=1 terrain_mutation=0 water_mutation=0 road_mutation=0 collision=0 shadows=0")
    quit(0)
