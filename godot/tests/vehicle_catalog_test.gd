extends SceneTree

const Catalog = preload("res://scripts/vehicle_catalog.gd")
const FleetRegistry = preload("res://scripts/vehicle_fleet_registry.gd")
const Controller = preload("res://scripts/vehicle_controller.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("VEHICLE_CATALOG_TEST: " + message)

func _check_profile(vehicle_id: String) -> Dictionary:
    _check(Catalog.has(vehicle_id), "Missing required vehicle profile " + vehicle_id)
    if not Catalog.has(vehicle_id):
        return {}
    var data := Catalog.profile(vehicle_id)
    for field in ["mass_kg", "wheelbase_m", "track_width_m", "max_forward_mps", "hero_scene"]:
        _check(data.has(field), "%s missing %s" % [vehicle_id, field])
    _check(not str(data.get("hero_scene", "")).is_empty(), "%s has no source hero scene" % vehicle_id)
    return data

func _run() -> void:
    # Crown remains the accepted baseline. The recovered fleet is additive and
    # must not be erased merely because public CI omits the private GLB pack.
    var crown := _check_profile("toyota_crown")
    _check(str(crown.get("hero_scene", "")) == "toyota_crown_2013.glb", "Crown does not target its dedicated hero scene")

    for recovered_id in [
        "audi_r8",
        "honda_s2000",
        "nissan_skyline_r34",
        "toyota_supra_rz",
        "carx_commodore",
        "carx_pontiac_solstice",
        "carx_charger_source",
    ]:
        _check(FleetRegistry.has(recovered_id), "Recovered registry missing " + recovered_id)
        var profile := _check_profile(recovered_id)
        _check(str(profile.get("id", "")) == recovered_id, "Recovered profile identity drifted for " + recovered_id)

    # Owner policy is authoritative over historical source/test state.
    for banned_id in ["toyota_mark_x", "toyota_mark_x_2013", "mark_x"]:
        _check(Catalog.is_banned(banned_id), "Mark X ban missing for " + banned_id)
        _check(not Catalog.has(banned_id), "Banned Mark X remains callable: " + banned_id)
        _check(not Catalog.production_ids().has(banned_id), "Banned Mark X remains selectable: " + banned_id)

    for excluded_id in ["port_royal_992", "porsche_911_992", "992"]:
        _check(Catalog.is_excluded(excluded_id), "992 exclusion missing for " + excluded_id)
        _check(not Catalog.has(excluded_id), "Excluded 992 remains callable: " + excluded_id)
        _check(not Catalog.production_ids().has(excluded_id), "Excluded 992 remains selectable: " + excluded_id)

    var legacy := Catalog.profile(Catalog.DEFAULT_ID)
    _check(str(legacy.get("hero_scene", "")).is_empty(), "Legacy sedan must remain generic and non-production")
    _check(not Catalog.production_ids().has(Catalog.DEFAULT_ID), "Legacy fallback leaked into production selector")

    # Controller baseline remains Crown. Private recovered hero media are tested
    # in owner builds; public source tests prove catalog/tuning integration only.
    var scene := Node3D.new()
    root.add_child(scene)
    var car := CharacterBody3D.new()
    car.collision_layer = 2
    car.collision_mask = 1
    var collider := CollisionShape3D.new()
    var shape := BoxShape3D.new()
    shape.size = Vector3(1.85, 1.30, 4.0)
    collider.shape = shape
    car.add_child(collider)
    scene.add_child(car)
    var controller = Controller.new()
    controller.configure(car, "toyota_crown")
    _check(controller.vehicle_id == "toyota_crown", "Controller did not apply Crown profile")
    _check(absf(controller.wheelbase_m - float(crown.get("wheelbase_m", 0.0))) < 0.001, "Controller ignored Crown wheelbase")

    print("YARDMAN_VEHICLE_CATALOG_TEST %s production=%d recovered=%d mark_x_banned=1 992_excluded=1" % [
        "PASS" if failures == 0 else "FAIL",
        Catalog.production_ids().size(),
        FleetRegistry.count(),
    ])
    scene.queue_free()
    await process_frame
    quit(0 if failures == 0 else 1)
