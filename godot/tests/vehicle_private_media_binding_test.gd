extends SceneTree

const VehicleScript = preload("res://scripts/vehicle_controller.gd")
const Catalog = preload("res://scripts/vehicle_catalog.gd")

var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(ok: bool, message: String) -> void:
    if not ok:
        failures += 1
        push_error("PRIVATE_FLEET_BINDING: " + message)

func _run() -> void:
    var requested := OS.get_environment("YARDMAN_VEHICLE_TEST_IDS").strip_edges()
    var ids: Array[String] = []
    for raw in requested.split(","):
        var vehicle_id := str(raw).strip_edges()
        if not vehicle_id.is_empty():
            ids.append(vehicle_id)
    _check(not ids.is_empty(), "no vehicle ids requested")

    var scene := Node3D.new()
    root.add_child(scene)
    for vehicle_id in ids:
        var profile: Dictionary = Catalog.profile(vehicle_id)
        _check(str(profile.get("id", "")) == vehicle_id, "%s catalog identity mismatch" % vehicle_id)
        var hero := str(profile.get("hero_scene", ""))
        _check(not hero.is_empty(), "%s has no hero_scene" % vehicle_id)

        var car := CharacterBody3D.new()
        car.name = "Car_" + vehicle_id
        var collision := CollisionShape3D.new()
        var box := BoxShape3D.new()
        box.size = Vector3(1.8, 1.1, 4.0)
        collision.shape = box
        car.add_child(collision)
        scene.add_child(car)

        var controller = VehicleScript.new()
        controller.configure(car, vehicle_id)
        var visual: Node3D = controller.visual
        _check(visual != null, "%s visual missing" % vehicle_id)
        if visual != null:
            _check(bool(visual.get("is_reference_model")), "%s did not bind real private hero %s" % [vehicle_id, hero])
            _check(str(visual.get("reference_asset_name")) == hero, "%s bound %s instead of %s" % [vehicle_id, str(visual.get("reference_asset_name")), hero])
            _check(bool(visual.get_meta("yardman_dedicated_vehicle_mesh", false)), "%s hero not marked dedicated" % vehicle_id)
            _check(str(visual.get_meta("yardman_dedicated_vehicle_id", "")) == vehicle_id, "%s dedicated id mismatch" % vehicle_id)
            _check((visual.get("front_pivots") as Array).size() == 2, "%s front pivot count mismatch" % vehicle_id)
            _check((visual.get("wheels") as Array).size() == 4, "%s wheel spin count mismatch" % vehicle_id)
            var bounds: AABB = visual.get("geometry_bounds")
            _check(bounds.position.is_finite() and bounds.size.is_finite(), "%s non-finite geometry bounds" % vehicle_id)
            _check(bounds.size.x > 1.0 and bounds.size.y > 0.5 and bounds.size.z > 2.0, "%s implausible geometry bounds %s" % [vehicle_id, bounds])

        var contract: Dictionary = controller.runtime_contract()
        _check(bool(contract.get("ready", false)), "%s runtime contract not ready: %s" % [vehicle_id, contract])
        for hook_name in ["CameraMount", "ExitPoint", "DriverSeat"]:
            var hook := controller.runtime_hook(hook_name)
            _check(hook != null and hook.position.is_finite(), "%s missing/invalid %s" % [vehicle_id, hook_name])

        var fitted := collision.shape as BoxShape3D
        _check(fitted != null and fitted.size.is_finite() and fitted.size.x > 0.0 and fitted.size.y > 0.0 and fitted.size.z > 0.0, "%s invalid fitted collider" % vehicle_id)
        if visual != null:
            print("PRIVATE_FLEET_BIND vehicle=%s hero=%s reference=%d bounds=%s wheelbase=%.3f track=%.3f wheel_radius=%.3f" % [vehicle_id, hero, int(bool(visual.get("is_reference_model"))), visual.get("geometry_bounds"), float(visual.get("wheelbase_m")), float(visual.get("track_width_m")), float(visual.get("wheel_radius_m"))])
        car.free()

    scene.free()
    print("YARDMAN_PRIVATE_FLEET_BINDING_TEST %s vehicles=%d failures=%d" % ["PASS" if failures == 0 else "FAIL", ids.size(), failures])
    quit(0 if failures == 0 else 1)
