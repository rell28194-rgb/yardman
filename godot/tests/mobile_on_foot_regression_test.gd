extends SceneTree

const PlayerScript = preload("res://scripts/player_controller.gd")
const TouchScript = preload("res://scripts/touch_controls.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("MOBILE_ON_FOOT_REGRESSION: " + message)

func _run() -> void:
    root.size = Vector2i(1280, 720)
    root.content_scale_size = Vector2i(1280, 720)

    var scene := Node3D.new()
    scene.name = "MobileOnFootRegression"
    root.add_child(scene)
    current_scene = scene

    var ground := StaticBody3D.new()
    ground.collision_layer = 1
    ground.collision_mask = 0
    var ground_shape := CollisionShape3D.new()
    var box := BoxShape3D.new()
    box.size = Vector3(40.0, 1.0, 40.0)
    ground_shape.shape = box
    ground_shape.position.y = -0.5
    ground.add_child(ground_shape)
    scene.add_child(ground)

    var car := CharacterBody3D.new()
    car.position = Vector3(8.0, 0.0, 0.0)
    scene.add_child(car)
    var vehicle_stub := {"body": car, "occupied": false, "speed_mps": 0.0}

    var player := PlayerScript.new()
    player.configure(vehicle_stub)
    scene.add_child(player)
    player.position = Vector3(0.0, 0.05, 0.0)
    player._set_occupied(false)

    var touch := TouchScript.new()
    scene.add_child(touch)
    touch.driving = false
    await physics_frame
    await physics_frame

    var origin := touch._center("stick")
    touch._press(11, origin)
    touch._drag(11, origin + Vector2(0.0, -110.0), Vector2(0.0, -110.0))
    var analog := touch.movement_vector()
    _check(analog.y < -0.85 and absf(analog.x) < 0.05, "walking stick did not produce forward analog input")

    var start := player.global_position
    for frame in range(120):
        player.movement = touch.movement_vector()
        player.camera_yaw = 0.0
        player.step(1.0 / 60.0, true)
        await physics_frame
    var travelled := Vector2(player.global_position.x - start.x, player.global_position.z - start.z).length()
    _check(travelled > 4.0, "touch walking did not move the player far enough: %.3f m" % travelled)
    _check(player.global_position.z < start.z - 3.5, "forward touch input moved in the wrong world direction")

    touch._release(11)
    var release_position := player.global_position
    for frame in range(45):
        player.movement = touch.movement_vector()
        player.step(1.0 / 60.0, true)
        await physics_frame
    _check(touch.movement_vector() == Vector2.ZERO, "released walking stick remained active")
    _check(Vector2(player.global_position.x - release_position.x, player.global_position.z - release_position.z).length() < 1.5, "player kept travelling after touch release")

    print("YARDMAN_MOBILE_ON_FOOT_REGRESSION %s touch_walk=1 direction=1 release=1 distance=%.2f" % ["PASS" if failures == 0 else "FAIL", travelled])
    current_scene = null
    scene.queue_free()
    await process_frame
    quit(0 if failures == 0 else 1)
