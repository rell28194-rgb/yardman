extends SceneTree

const PlayerScript = preload("res://scripts/player_controller.gd")
var failures := 0

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("VEHICLE_ENTRY_CYCLE_REGRESSION: " + message)

func _initialize() -> void:
    call_deferred("_run")

func _run() -> void:
    var scene := Node3D.new()
    scene.name = "VehicleEntryCycleRegression"
    root.add_child(scene)
    current_scene = scene

    var ground := StaticBody3D.new()
    ground.collision_layer = 1
    ground.collision_mask = 0
    var ground_collider := CollisionShape3D.new()
    var ground_shape := BoxShape3D.new()
    ground_shape.size = Vector3(30.0, 1.0, 30.0)
    ground_collider.shape = ground_shape
    ground_collider.position.y = -0.5
    ground.add_child(ground_collider)
    scene.add_child(ground)

    var car := CharacterBody3D.new()
    car.name = "CycleCar"
    car.collision_layer = 2
    car.collision_mask = 1
    var car_collider := CollisionShape3D.new()
    var car_shape := BoxShape3D.new()
    car_shape.size = Vector3(1.85, 1.30, 4.0)
    car_collider.shape = car_shape
    car_collider.position.y = 0.65
    car.add_child(car_collider)
    scene.add_child(car)

    var vehicle_stub := {"body": car, "occupied": true, "speed_mps": 0.0}
    var player := PlayerScript.new()
    player.name = "CyclePlayer"
    player.configure(vehicle_stub)
    scene.add_child(player)
    await physics_frame
    await physics_frame

    _check(player.in_vehicle, "player did not start in vehicle")
    _check(player.can_exit_vehicle(), "stopped vehicle rejected exit")
    var exited := player.try_exit_vehicle()
    _check(exited, "safe-ground exit failed")
    _check(not player.in_vehicle, "player occupancy did not clear after exit")
    _check(player.visible, "player remained hidden after exit")
    _check(player.global_position.distance_to(car.global_position) > 1.0, "exit position remained inside car")
    _check(player.can_enter_vehicle(), "valid exit position is outside re-entry reach")
    var reentered := player.try_enter_vehicle()
    _check(reentered, "re-entry failed after valid exit")
    _check(player.in_vehicle and not player.visible, "re-entry did not restore occupied state")

    vehicle_stub.speed_mps = 4.5
    _check(not player.can_exit_vehicle(), "moving car still permits exit")

    print("YARDMAN_VEHICLE_ENTRY_CYCLE_REGRESSION %s exit=1 clear=1 reenter=1 moving_lockout=1" % ("PASS" if failures == 0 else "FAIL"))
    current_scene = null
    scene.queue_free()
    await process_frame
    quit(0 if failures == 0 else 1)
