extends SceneTree

const VehicleScript = preload("res://scripts/vehicle_controller.gd")
const Catalog = preload("res://scripts/vehicle_catalog.gd")

var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("VEHICLE_GAME_READY_TEST: " + message)

func _step_frames(controller, frames: int, throttle: float = 0.0, turn: float = 0.0, ready: bool = true) -> void:
    for frame in range(frames):
        await physics_frame
        controller.step(1.0 / 60.0, throttle, turn, ready)

func _settle(controller, car: CharacterBody3D) -> void:
    controller.reset_motion()
    car.position.y = 0.15
    car.rotation = Vector3.ZERO
    await _step_frames(controller, 40)

func _make_car(scene: Node3D, vehicle_id: String, index: int) -> Dictionary:
    var car := CharacterBody3D.new()
    car.name = "GameReady_%s" % vehicle_id
    car.collision_layer = 2
    car.collision_mask = 1
    car.position = Vector3(float(index) * 8.0, 0.15, 0.0)
    var collision := CollisionShape3D.new()
    collision.name = "BodyCollision"
    var shape := BoxShape3D.new()
    shape.size = Vector3(1.85, 1.30, 4.0)
    collision.shape = shape
    collision.position.y = 0.65
    car.add_child(collision)
    scene.add_child(car)
    var controller = VehicleScript.new()
    controller.configure(car, vehicle_id)
    return {"car": car, "collision": collision, "controller": controller}

func _check_local_contract(vehicle_id: String, car: CharacterBody3D, collision: CollisionShape3D, controller) -> void:
    _check(controller.vehicle_id == vehicle_id, "%s selector resolved to %s" % [vehicle_id, controller.vehicle_id])
    var audit: Dictionary = controller.runtime_contract()
    _check(bool(audit.get("ready", false)), "%s runtime node contract is not ready: %s" % [vehicle_id, str(audit)])
    _check(int(audit.get("visual_rig_count", 0)) == 1, "%s does not own exactly one VisualRig" % vehicle_id)
    for hook_name in ["CameraMount", "ExitPoint", "DriverSeat"]:
        _check(controller.runtime_hook(hook_name) != null, "%s missing %s" % [vehicle_id, hook_name])
        _check(car.find_children(hook_name, "Marker3D", true, false).size() == 1, "%s duplicated %s" % [vehicle_id, hook_name])
    var box := collision.shape as BoxShape3D
    _check(box != null, "%s lost its box collider" % vehicle_id)
    if box != null:
        _check(box.size.x > 0.5 and box.size.y > 0.5 and box.size.z > 1.0, "%s collider dimensions are invalid" % vehicle_id)
        _check(is_finite(box.size.x) and is_finite(box.size.y) and is_finite(box.size.z), "%s collider dimensions are non-finite" % vehicle_id)
    _check(controller.visual != null and controller.visual.get_parent() == car, "%s visual is not locally owned by the vehicle" % vehicle_id)

func _exercise_vehicle(scene: Node3D, vehicle_id: String, index: int) -> void:
    var built := _make_car(scene, vehicle_id, index)
    var car := built.car as CharacterBody3D
    var collision := built.collision as CollisionShape3D
    var controller = built.controller

    _check_local_contract(vehicle_id, car, collision, controller)

    # Re-applying the selector must rebuild in place without duplicate game-facing nodes.
    controller.apply_profile(vehicle_id)
    controller.apply_profile(vehicle_id)
    _check_local_contract(vehicle_id, car, collision, controller)

    await _settle(controller, car)
    _check(car.is_on_floor(), "%s did not settle on the isolated test floor" % vehicle_id)

    var start_z := car.position.z
    await _step_frames(controller, 180, 1.0)
    _check(controller.speed_mps > 1.0, "%s failed forward drive" % vehicle_id)
    _check(car.position.z < start_z - 2.0, "%s reported forward speed without meaningful travel" % vehicle_id)

    controller.brake_input = 1.0
    await _step_frames(controller, 240, 1.0)
    _check(absf(controller.speed_mps) < 0.10, "%s service brake failed to stop" % vehicle_id)

    controller.brake_input = 0.0
    await _step_frames(controller, 150, -1.0)
    _check(controller.speed_mps < -0.5, "%s failed reverse drive" % vehicle_id)
    _check(controller.gear_label() == "R", "%s reverse gear state is incorrect" % vehicle_id)

    await _settle(controller, car)
    await _step_frames(controller, 120, 1.0)
    var yaw_before := car.rotation.y
    await _step_frames(controller, 20, 0.65, 0.65)
    _check(absf(controller.steering_angle) > 0.001, "%s steering input did not produce steering angle" % vehicle_id)
    _check(absf(car.rotation.y - yaw_before) > 0.0001, "%s steering did not rotate the vehicle" % vehicle_id)

    controller.exit_vehicle()
    _check(not controller.occupied and controller.gear_label() == "P", "%s did not enter parked state on exit" % vehicle_id)
    var parked_position := car.position
    await _step_frames(controller, 60, 1.0, 1.0)
    _check(controller.speed_mps == 0.0, "%s accepted throttle while exited" % vehicle_id)
    _check(car.position.distance_to(parked_position) < 0.05, "%s moved materially while exited" % vehicle_id)

    controller.enter_vehicle()
    _check(controller.occupied, "%s failed re-entry" % vehicle_id)
    await _step_frames(controller, 90, 1.0)
    _check(controller.speed_mps > 0.5, "%s did not resume driving after re-entry" % vehicle_id)

    controller.reset_motion()
    _check(controller.speed_mps == 0.0 and car.velocity == Vector3.ZERO, "%s reset left residual motion" % vehicle_id)
    _check(bool(controller.runtime_contract().get("ready", false)), "%s runtime contract regressed after lifecycle exercise" % vehicle_id)

    var car_name := car.name
    car.free()
    _check(scene.get_node_or_null(car_name) == null, "%s despawn left the vehicle node attached" % vehicle_id)

func _run() -> void:
    var scene := Node3D.new()
    root.add_child(scene)

    var ground := StaticBody3D.new()
    ground.collision_layer = 1
    var ground_collision := CollisionShape3D.new()
    var ground_shape := BoxShape3D.new()
    ground_shape.size = Vector3(200.0, 1.0, 400.0)
    ground_collision.shape = ground_shape
    ground.position.y = -0.5
    ground.add_child(ground_collision)
    scene.add_child(ground)

    var production_ids: Array = Catalog.production_ids()
    _check(not production_ids.is_empty(), "production catalog is empty")
    for index in range(production_ids.size()):
        await _exercise_vehicle(scene, str(production_ids[index]), index)

    print("YARDMAN_VEHICLE_GAME_READY_TEST %s vehicles=%d hooks=1 drive=1 reverse=1 steering=1 braking=1 park_exit_reenter=1 reset_despawn=1" % ["PASS" if failures == 0 else "FAIL", production_ids.size()])
    scene.queue_free()
    await process_frame
    quit(0 if failures == 0 else 1)