extends SceneTree

const VehicleScript = preload("res://scripts/vehicle_controller.gd")
const Catalog = preload("res://scripts/vehicle_catalog.gd")

var failures := 0

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("PRIVATE_OWNER_FLEET_RUNTIME_TEST: " + message)

func _finite_vector(value: Vector3) -> bool:
    return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)

func _initialize() -> void:
    call_deferred("_run")

func _run() -> void:
    var ids: Array = Catalog.production_ids()
    _check(ids.size() == 64, "Expected authoritative 64-car selector, got %d" % ids.size())
    _check(not ids.has("toyota_mark_x"), "Banned Mark X entered owner selector")
    _check(not ids.has("port_royal_992"), "Banned 992 entered owner selector")
    _check(not ids.has("corvette_c7"), "Held C7 entered owner selector")
    _check(not ids.has("delorean_dmc12"), "Held DMC-12 entered owner selector")

    var scene := Node3D.new()
    root.add_child(scene)
    var car := CharacterBody3D.new()
    car.name = "OwnerFleetRuntimeCar"
    car.collision_layer = 2
    car.collision_mask = 1
    var collider := CollisionShape3D.new()
    var shape := BoxShape3D.new()
    shape.size = Vector3(1.85, 1.30, 4.0)
    collider.shape = shape
    collider.position.y = 0.65
    car.add_child(collider)
    scene.add_child(car)

    var controller = VehicleScript.new()
    controller.configure(car, str(ids[0]))
    var validated := 0
    for raw_id in ids:
        var vehicle_id := str(raw_id)
        controller.apply_profile(vehicle_id)
        await process_frame
        var profile: Dictionary = controller.profile_metadata()
        var visual: Node3D = controller.visual
        _check(str(controller.vehicle_id) == vehicle_id, "%s controller identity changed to %s" % [vehicle_id, str(controller.vehicle_id)])
        _check(str(profile.get("id", "")) == vehicle_id, "%s profile identity mismatch" % vehicle_id)
        _check(visual != null, "%s has no visual" % vehicle_id)
        if visual == null:
            continue
        _check(bool(visual.get_meta("yardman_dedicated_vehicle_mesh", false)), "%s did not load a dedicated hero" % vehicle_id)
        _check(not bool(visual.get_meta("yardman_hero_asset_missing_or_invalid", false)), "%s dedicated hero is missing/invalid" % vehicle_id)
        _check(not bool(visual.get_meta("yardman_procedural_vehicle_fallback", false)), "%s used procedural fallback" % vehicle_id)
        _check(str(visual.get("reference_asset_name")) == str(profile.get("hero_scene", "")), "%s loaded wrong hero scene" % vehicle_id)
        var wheels: Array = visual.get("wheels")
        var pivots: Array = visual.get("front_pivots")
        _check(wheels.size() == 4, "%s does not have four runtime wheel spins" % vehicle_id)
        _check(pivots.size() == 2, "%s does not have two steering pivots" % vehicle_id)
        var bounds: AABB = visual.get("geometry_bounds")
        _check(_finite_vector(bounds.position) and _finite_vector(bounds.size), "%s has non-finite geometry bounds" % vehicle_id)
        _check(bounds.size.x > 0.5 and bounds.size.y > 0.4 and bounds.size.z > 1.5, "%s has implausible geometry bounds %s" % [vehicle_id, str(bounds.size)])
        _check(is_finite(float(visual.get("wheelbase_m"))) and float(visual.get("wheelbase_m")) > 1.5, "%s has invalid wheelbase" % vehicle_id)
        _check(is_finite(float(visual.get("wheel_radius_m"))) and float(visual.get("wheel_radius_m")) > 0.15, "%s has invalid wheel radius" % vehicle_id)
        var audit: Dictionary = controller.runtime_contract()
        _check(bool(audit.get("ready", false)), "%s runtime hooks are not ready: %s" % [vehicle_id, str(audit)])
        _check((audit.get("missing_hooks", []) as Array).is_empty(), "%s missing runtime hooks" % vehicle_id)
        _check((audit.get("duplicate_hooks", []) as Array).is_empty(), "%s duplicate runtime hooks" % vehicle_id)
        _check(int(audit.get("visual_rig_count", 0)) == 1, "%s visual rig count drifted" % vehicle_id)
        controller.exit_vehicle()
        _check(not controller.occupied and absf(controller.speed_mps) < 0.001, "%s exit/reset lifecycle failed" % vehicle_id)
        controller.enter_vehicle()
        _check(controller.occupied, "%s re-entry lifecycle failed" % vehicle_id)
        validated += 1

    print("YARDMAN_PRIVATE_OWNER_FLEET_RUNTIME_TEST %s vehicles=%d dedicated=%d banned_absent=2 held_absent=2" % [
        "PASS" if failures == 0 else "FAIL", ids.size(), validated])
    scene.queue_free()
    await process_frame
    quit(0 if failures == 0 else 1)
