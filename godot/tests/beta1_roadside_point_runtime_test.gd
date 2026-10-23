extends SceneTree

const Runtime = preload("res://scripts/beta1_roadside_point_runtime.gd")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("BETA1_ROADSIDE_POINT_RUNTIME_TEST: " + message)
    quit(1)

func _run() -> void:
    var lamp_record := {
        "id": "n101",
        "kind": "street_lamp",
        "position": [120.5, 77.0, -44.25],
        "source_tags": {"highway": "street_lamp"},
    }
    var lamp_copy := lamp_record.duplicate(true)
    var lamp_plan := Runtime.point_plan(lamp_record)
    if str(lamp_plan.get("kind", "")) != "street_lamp" \
            or lamp_plan.get("point", Vector2.ZERO) != Vector2(120.5, -44.25):
        _fail("explicit lamp point was not preserved exactly")
        return
    if bool(lamp_plan.get("position_inference", true)):
        _fail("lamp point gained position inference")
        return

    var shelter_record := {
        "id": "n202",
        "kind": "bus_shelter",
        "position": [-8.0, 2.0, 19.0],
        "source_tags": {"highway": "bus_stop", "shelter": "yes"},
    }
    if str(Runtime.point_plan(shelter_record).get("kind", "")) != "bus_shelter":
        _fail("shelter-authorized bus stop was rejected")
        return
    var unsheltered := shelter_record.duplicate(true)
    unsheltered.source_tags = {"highway": "bus_stop", "shelter": "no"}
    if not Runtime.point_plan(unsheltered).is_empty():
        _fail("unsheltered bus stop received shelter geometry")
        return
    var fake_lamp := lamp_record.duplicate(true)
    fake_lamp.source_tags = {"highway": "traffic_signals"}
    if not Runtime.point_plan(fake_lamp).is_empty():
        _fail("non-lamp source tag received lamp geometry")
        return
    var unknown := lamp_record.duplicate(true)
    unknown.kind = "guardrail"
    if not Runtime.point_plan(unknown).is_empty():
        _fail("unknown roadside family was accepted")
        return
    if lamp_record != lamp_copy:
        _fail("point planner mutated source truth")
        return

    var toward_road := Runtime.orientation_basis(
        Vector2(0.0, 0.0), {"point": Vector2(0.0, 10.0)}, "n101")
    var forward := toward_road.z.normalized()
    if forward.dot(Vector3(0.0, 0.0, 1.0)) < 0.99:
        _fail("orientation inference did not face nearest compiled road")
        return
    var fallback_a := Runtime.orientation_basis(Vector2.ZERO, {}, "n101")
    var fallback_b := Runtime.orientation_basis(Vector2.ZERO, {}, "n101")
    if not fallback_a.is_equal_approx(fallback_b):
        _fail("missing-road orientation fallback is not deterministic")
        return

    var contract := Runtime.asset_contract()
    var files: Dictionary = contract.get("files", {})
    if str(files.get("street_lamp", "")) != "road_lamp_single_arm.glb" \
            or str(files.get("bus_shelter", "")) != "road_bus_stop_shelter.glb":
        _fail("recovered roadside asset filenames drifted")
        return
    if bool(contract.get("position_inference", true)) \
            or bool(contract.get("routing", true)) or bool(contract.get("navigation", true)) \
            or bool(contract.get("collision", true)) or bool(contract.get("terrain_mutation", true)):
        _fail("roadside point runtime gained geographic/physics authority")
        return
    if not bool(contract.get("orientation_inference", false)) \
            or not bool(contract.get("asset_absent_fallback", false)) \
            or not bool(contract.get("data_absent_fallback", false)):
        _fail("orientation/fallback contract is incomplete")
        return
    if int(contract.get("max_points_per_tile", 999)) > 32 or float(contract.get("visibility_m", 999.0)) > 200.0:
        _fail("roadside point runtime exceeded bounded near-field budget")
        return

    print("YARDMAN_BETA1_ROADSIDE_POINT_RUNTIME_TEST PASS lamp=1 shelter=1 unsheltered_rejected=1 fake_lamp_rejected=1 source_unchanged=1 exact_position=1 orientation_only=1 near_only=1 collision=0")
    quit(0)
