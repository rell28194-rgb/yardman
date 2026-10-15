extends SceneTree

const Catalog = preload("res://scripts/vehicle_catalog.gd")
const Controller = preload("res://scripts/vehicle_controller.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("VEHICLE_CATALOG_TEST: " + message)

func _run() -> void:
    var required := ["toyota_crown", "toyota_mark_x", "port_royal_992"]
    for vehicle_id in required:
        _check(Catalog.has(vehicle_id), "Missing required vehicle profile " + vehicle_id)
        var data := Catalog.profile(vehicle_id)
        for field in ["mass_kg", "wheelbase_m", "track_width_m", "cg_height_m", "max_forward_mps", "brake_decel_mps2", "steering_low_deg", "audio_profile", "hero_scene"]:
            _check(data.has(field), "%s missing %s" % [vehicle_id, field])
    var legacy := Catalog.profile(Catalog.DEFAULT_ID)
    var crown := Catalog.profile("toyota_crown")
    var mark_x := Catalog.profile("toyota_mark_x")
    var sports := Catalog.profile("port_royal_992")
    _check(str(crown.hero_scene) == "toyota_crown_2013.glb", "Crown does not target its recovered dedicated hero scene")
    _check(str(mark_x.hero_scene).is_empty(), "Mark X must stay on fallback art until a verified Mark X source is recovered")
    _check(str(sports.hero_scene).is_empty(), "Port Royal 992 must not bind Porsche/source hero art")
    _check(str(legacy.hero_scene).is_empty(), "Legacy sedan must remain a generic fallback profile")
    _check(float(crown.mass_kg) != float(mark_x.mass_kg), "Crown and Mark X still share identical mass tuning")
    _check(float(mark_x.max_forward_mps) != float(sports.max_forward_mps), "Mark X and 992-class car still share identical speed tuning")
    _check(float(crown.wheelbase_m) != float(sports.wheelbase_m), "Sedan and sports-car wheelbase are not distinct")
    _check(str(crown.audio_profile) != str(mark_x.audio_profile) and str(mark_x.audio_profile) != str(sports.audio_profile), "Required cars do not have distinct audio profile identities")

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
    _check(absf(controller.wheelbase_m - float(crown.wheelbase_m)) < 0.001, "Controller ignored Crown wheelbase")
    var crown_collider := (collider.shape as BoxShape3D).size
    controller.apply_profile("port_royal_992")
    _check(controller.vehicle_id == "port_royal_992", "Runtime profile switch did not apply")
    _check(absf(controller.wheelbase_m - float(sports.wheelbase_m)) < 0.001, "Runtime profile switch kept old wheelbase")
    _check(not (collider.shape as BoxShape3D).size.is_equal_approx(crown_collider), "Profile switch did not update physical vehicle bounds")
    _check(controller.audio_profile() == str(sports.audio_profile), "Profile switch did not update audio identity")
    print("YARDMAN_VEHICLE_CATALOG_TEST %s profiles=%d hero_contract=1 switch=1" % ["PASS" if failures == 0 else "FAIL", Catalog.production_ids().size()])
    scene.queue_free()
    await process_frame
    quit(0 if failures == 0 else 1)
