extends SceneTree

const Catalog = preload("res://scripts/vehicle_catalog.gd")
const VehicleScript = preload("res://scripts/vehicle_controller.gd")

var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("MAP_CARS_VEHICLE_RECOVERY: " + message)

func _run() -> void:
    _check(Catalog.DEFAULT_ID == "toyota_crown", "Crown is not the default owner vehicle")
    _check(not Catalog.has("toyota_mark_x"), "retired Mark X selector is still exposed")
    _check(not Catalog.has("port_royal_992"), "retired 992 selector is still exposed")

    var ids: Array = Catalog.production_ids()
    _check(ids.size() >= 18, "recovered fleet is missing; selectors=%d" % ids.size())
    _check(ids.has("toyota_crown"), "Crown is absent from recovered fleet")
    for vehicle_id in ids:
        var selector := str(vehicle_id).to_lower()
        _check(selector != "toyota_mark_x", "Mark X leaked into production selectors")
        _check(not selector.contains("992"), "992 leaked into production selectors: %s" % selector)

    var body := CharacterBody3D.new()
    body.name = "RecoveryVehicle"
    var collision := CollisionShape3D.new()
    var shape := BoxShape3D.new()
    shape.size = Vector3(1.85, 1.30, 4.0)
    collision.shape = shape
    body.add_child(collision)
    root.add_child(body)

    var controller = VehicleScript.new()
    controller.configure(body, "toyota_crown")
    _check(controller.vehicle_id == "toyota_crown", "controller did not bind Crown")
    _check(str(controller.profile_metadata().get("hero_scene", "")) == "toyota_crown_2013.glb", "Crown hero identity changed")

    var recovered_id := ""
    for vehicle_id in ids:
        if str(vehicle_id) != "toyota_crown":
            recovered_id = str(vehicle_id)
            break
    _check(not recovered_id.is_empty(), "no recovered non-Crown vehicle is selectable")
    if not recovered_id.is_empty():
        controller.apply_profile(recovered_id)
        _check(controller.vehicle_id == recovered_id, "recovered vehicle selector did not reach controller: %s" % recovered_id)

    controller.apply_profile("toyota_mark_x")
    _check(controller.vehicle_id == "toyota_crown", "blocked Mark X request did not normalize to Crown")
    controller.apply_profile("port_royal_992")
    _check(controller.vehicle_id == "toyota_crown", "blocked 992 request did not normalize to Crown")

    body.queue_free()
    await process_frame
    if failures == 0:
        print("YARDMAN_MAP_CARS_VEHICLE_RECOVERY PASS selectors=%d recovered_sample=%s" % [ids.size(), recovered_id])
    else:
        print("YARDMAN_MAP_CARS_VEHICLE_RECOVERY FAIL failures=%d" % failures)
    quit(failures)
