extends SceneTree

const Fords = preload("res://scripts/ford_surface_runtime.gd")
const FordShader = preload("res://shaders/ford_surface.gdshader")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("FORD_SURFACE_RUNTIME_TEST: " + message)
    quit(1)

func _run() -> void:
    var crossing := {
        "x": 102.0,
        "z": 205.0,
        "status": "approved",
        "kind": "ford",
        "road_width_m": 8.0,
        "road_edge": "road-17",
    }
    var crossing_copy := crossing.duplicate(true)
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
    if not Fords.ford_eligible(crossing):
        _fail("approved ford was rejected")
        return
    var selected := Fords.select_road_record(crossing, [road])
    if selected.is_empty():
        _fail("exact compiled ford road edge was not resolved")
        return
    var plan := Fords.ford_plan(crossing, water_a, water_b, 3.0, selected)
    if plan.is_empty():
        _fail("approved ford produced no shallow crossing plan")
        return
    if crossing != crossing_copy or road != road_copy:
        _fail("ford planner/resolver mutated source truth")
        return
    if not bool(plan.get("continuous_water", false)):
        _fail("ford plan no longer preserves continuous base hydrology")
        return
    var expected_half_path := 8.0 * 0.5 + Fords.ROAD_OVERLAP_M
    if absf(float(plan.get("half_path_m", 0.0)) - expected_half_path) > 0.001 \
            or absf(float(plan.get("oblique_factor", 0.0)) - 1.0) > 0.001:
        _fail("perpendicular ford path does not match exact road ribbon")
        return
    var crossing_point := Vector2(float(crossing.x), float(crossing.z))
    var road_normal: Vector2 = plan.get("road_normal", Vector2.ZERO)
    for key in ["start", "finish"]:
        var point3: Vector3 = plan.get(key, Vector3(INF, INF, INF))
        var point2 := Vector2(point3.x, point3.z)
        if absf(absf((point2 - crossing_point).dot(road_normal)) - expected_half_path) > 0.001:
            _fail("ford overlay endpoint missed exact road-edge overlap plane")
            return
        if not is_finite(point3.y):
            _fail("ford overlay elevation is invalid")
            return
    var center_y := (float(plan.start.y) + float(plan.finish.y)) * 0.5
    if absf(center_y - (12.0 + Fords.FORD_SURFACE_LIFT_M)) > 0.001:
        _fail("ford overlay does not sit at bounded shallow-water lift")
        return
    if float(plan.get("surface_width_m", 0.0)) < float(plan.get("water_width_m", 999.0)):
        _fail("ford overlay is narrower than compiled channel")
        return

    var unpaved_road := road.duplicate(true)
    unpaved_road["flags"] = 8
    var unpaved := Fords.ford_plan(crossing, water_a, water_b, 3.0,
        Fords.select_road_record(crossing, [unpaved_road]))
    if unpaved.is_empty() or not bool(unpaved.get("unpaved", false)):
        _fail("compiled unpaved road state was not preserved for ford material")
        return

    var oblique_road := {
        "a": Vector2(92.0, 195.0),
        "b": Vector2(112.0, 215.0),
        "width_m": 8.0,
        "edge_id": "road-17",
        "flags": 0,
    }
    var oblique := Fords.ford_plan(crossing, water_a, water_b, 3.0,
        Fords.select_road_record(crossing, [oblique_road]))
    if oblique.is_empty() or absf(float(oblique.get("oblique_factor", 0.0)) - sqrt(2.0)) > 0.002:
        _fail("45-degree ford did not use exact oblique road traversal")
        return
    var oblique_normal: Vector2 = oblique.get("road_normal", Vector2.ZERO)
    for key in ["start", "finish"]:
        var point3: Vector3 = oblique.get(key, Vector3(INF, INF, INF))
        var point2 := Vector2(point3.x, point3.z)
        if absf(absf((point2 - crossing_point).dot(oblique_normal)) - expected_half_path) > 0.002:
            _fail("oblique ford endpoint missed road-edge overlap plane")
            return

    var parallel_road := {
        "a": Vector2(102.0, 190.0), "b": Vector2(102.0, 220.0),
        "width_m": 8.0, "edge_id": "road-17", "flags": 0,
    }
    var parallel_record := Fords.select_road_record(crossing, [parallel_road])
    if parallel_record.is_empty() or not Fords.ford_plan(crossing, water_a, water_b, 3.0, parallel_record).is_empty():
        _fail("near-parallel ford geometry did not fail closed")
        return

    var bridge_road := road.duplicate(true)
    bridge_road["flags"] = 2
    if not Fords.select_road_record(crossing, [bridge_road]).is_empty():
        _fail("bridge road record entered ford overlay path")
        return
    var tunnel_road := road.duplicate(true)
    tunnel_road["flags"] = 4
    if not Fords.select_road_record(crossing, [tunnel_road]).is_empty():
        _fail("tunnel road record entered ford overlay path")
        return
    var wrong_edge := road.duplicate(true)
    wrong_edge["edge_id"] = "road-99"
    if not Fords.select_road_record(crossing, [wrong_edge]).is_empty():
        _fail("wrong road edge ID was accepted")
        return
    var wrong_width := road.duplicate(true)
    wrong_width["width_m"] = 7.4
    if not Fords.select_road_record(crossing, [wrong_width]).is_empty():
        _fail("road width inconsistent with v2 crossing truth was accepted")
        return
    var off_center := road.duplicate(true)
    off_center["a"] = Vector2(90.0, 206.0)
    off_center["b"] = Vector2(114.0, 206.0)
    if not Fords.select_road_record(crossing, [off_center]).is_empty():
        _fail("road outside crossing centerline tolerance was accepted")
        return

    var culvert := crossing.duplicate(true)
    culvert["kind"] = "culvert"
    if Fords.ford_eligible(culvert):
        _fail("culvert entered ford path")
        return
    var unresolved := crossing.duplicate(true)
    unresolved["status"] = "unresolved"
    if Fords.ford_eligible(unresolved):
        _fail("unresolved crossing entered ford path")
        return
    var missing_edge := crossing.duplicate(true)
    missing_edge.erase("road_edge")
    if Fords.ford_eligible(missing_edge):
        _fail("ford without exact road edge was accepted")
        return

    var shader_code := FordShader.code
    if not shader_code.contains("reference_gravel") or not shader_code.contains("end_fade") \
            or not shader_code.contains("side_fade") or not shader_code.contains("ALPHA"):
        _fail("ford shallow-water/gravel/fade shader contract drifted")
        return

    var contract := Fords.runtime_contract()
    if int(contract.get("format_version", 0)) != 2 or str(contract.get("status", "")) != "approved" \
            or str(contract.get("kind", "")) != "ford":
        _fail("approved v2 ford contract drifted")
        return
    if int(contract.get("max_fords", 999)) > 24 or int(contract.get("max_fords_per_tile", 999)) > 8 \
            or float(contract.get("visibility_m", 999.0)) > 200.0:
        _fail("ford presentation exceeded bounded Android budget")
        return
    if str(contract.get("gravel_asset", "")) != "road_gravel.png" \
            or absf(float(contract.get("surface_lift_m", 0.0)) - Fords.FORD_SURFACE_LIFT_M) > 0.0001:
        _fail("ford material/lift binding drifted")
        return
    if not bool(contract.get("continuous_base_water", false)) or bool(contract.get("water_clipping", true)) \
            or not bool(contract.get("exact_road_edge_required", false)) or not bool(contract.get("oblique_road_edges", false)):
        _fail("ford lost continuous-water/exact-road reconciliation contract")
        return
    if bool(contract.get("terrain_mutation", true)) or bool(contract.get("hydrology_mutation", true)) \
            or bool(contract.get("road_mutation", true)) or bool(contract.get("collision", true)) \
            or bool(contract.get("shadows", true)):
        _fail("ford presentation gained world/physics authority")
        return

    print("YARDMAN_FORD_SURFACE_RUNTIME_TEST PASS approved=1 continuous_water=1 exact_edge=1 oblique=1 unpaved=1 bridge_rejected=1 tunnel_rejected=1 unresolved_rejected=1 source_unchanged=1 terrain_mutation=0 hydrology_mutation=0 road_mutation=0 collision=0 shadows=0")
    quit(0)
