extends SceneTree

const WorkZones = preload("res://scripts/beta1_work_zone_runtime.gd")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("BETA1_WORK_ZONE_RUNTIME_TEST: " + message)
    quit(1)

func _run() -> void:
    var open_record := {
        "a": [0.0, 0.0, 0.0],
        "b": [32.0, 0.0, 0.0],
        "width_m": 6.4,
        "access": "yes",
        "construction_class": "primary",
    }
    var open_copy := open_record.duplicate(true)
    var open_plan := WorkZones.placement_plan(open_record)
    var cone_count := 0
    var closure_count := 0
    for plan: Dictionary in open_plan:
        if str(plan.get("kind", "")) == "cone":
            cone_count += 1
        else:
            closure_count += 1
    if cone_count < 2 or cone_count > WorkZones.MAX_CONES_PER_SEGMENT or closure_count != 0:
        _fail("open construction way did not produce bounded cones-only placement")
        return

    var closed := open_record.duplicate(true)
    closed["access"] = "no"
    var closed_plan := WorkZones.placement_plan(closed)
    var barriers := 0
    for plan: Dictionary in closed_plan:
        if str(plan.get("kind", "")) == "barrier":
            barriers += 1
    if barriers != 2:
        _fail("closed wide work zone did not get endpoint barriers")
        return

    var narrow := {
        "a": [0.0, 0.0, 0.0],
        "b": [18.0, 0.0, 0.0],
        "width_m": 3.4,
        "access": "private",
    }
    var fences := 0
    for plan: Dictionary in WorkZones.placement_plan(narrow):
        if str(plan.get("kind", "")) == "fence":
            fences += 1
    if fences != 2:
        _fail("closed narrow work zone did not get endpoint portable fences")
        return

    if open_record != open_copy:
        _fail("placement mutated source construction record")
        return
    if not WorkZones.placement_plan({"a": [0.0, 0.0, 0.0], "b": [0.5, 0.0, 0.0]}).is_empty():
        _fail("degenerate work-zone segment generated props")
        return

    var contract := WorkZones.asset_contract()
    var files: Dictionary = contract.get("files", {})
    if str(files.get("cone", "")) != "road_repair_cone.glb" \
            or str(files.get("barrier", "")) != "road_concrete_barrier.glb" \
            or str(files.get("fence", "")) != "road_portable_fence.glb":
        _fail("recovered construction prop filenames drifted")
        return
    if str(contract.get("source_tag", "")) != "highway=construction" \
            or not bool(contract.get("access_closure_only", false)):
        _fail("source-backed construction placement contract drifted")
        return
    if bool(contract.get("drivable", true)) or bool(contract.get("navigation", true)) \
            or bool(contract.get("collision", true)) or bool(contract.get("terrain_mutation", true)):
        _fail("work-zone presentation gained gameplay/terrain authority")
        return
    if int(contract.get("max_props_per_tile", 999)) > 64 or float(contract.get("visibility_m", 999.0)) > 160.0:
        _fail("work-zone presentation exceeded bounded Android budget")
        return
    if not bool(contract.get("source_scale_preserved", false)) \
            or not bool(contract.get("asset_absent_fallback", false)) \
            or not bool(contract.get("data_absent_fallback", false)):
        _fail("source-scale/fallback contract missing")
        return

    print("YARDMAN_BETA1_WORK_ZONE_RUNTIME_TEST PASS cones=%d barriers=2 fences=2 source_unchanged=1 access_gated=1 drivable=0 navigation=0 collision=0 terrain_mutation=0")
    quit(0)
