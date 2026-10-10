extends SceneTree

const SaveScript = preload("res://scripts/save_game.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("GAMEPLAY_TEST: " + message)

func _wait_ready(scene) -> void:
    for frame in range(1800):
        await physics_frame
        var body: CharacterBody3D = scene.car if scene.player.in_vehicle else scene.player
        if scene.world_ready and body.is_on_floor():
            for settle in range(6):
                await physics_frame
            return
    _check(false, "Terrain/physics did not become ready in " + scene.current_parish)

func _run() -> void:
    var scene = load("res://main.tscn").instantiate()
    root.add_child(scene)
    await _wait_ready(scene)
    _check(scene.roads.manifest.parish_anchors.size() == 14, "All fourteen parishes must be addressable")
    for parish in scene.roads.manifest.parish_anchors:
        scene.goto_parish(str(parish))
        await _wait_ready(scene)
        var world: PackedFloat64Array = scene.roads.local_to_world(scene.car.position)
        var ground: float = scene.terrain.height_at(world[0], world[2])
        _check(is_finite(ground) and absf(world[1] - ground) < 1.0, "Car did not settle on real terrain in " + str(parish))
        _check(scene.car.position.length() < 3000.0, "Parish travel bypassed local origin rebasing")
        _check(scene.terrain._loaded.size() <= 25, "Terrain residency exceeds the configured bounded ring")
    scene.goto_parish("St. Mary")
    await _wait_ready(scene)
    scene.vehicle.speed_mps = 4.0
    _check(not scene.player.try_exit_vehicle(), "Exit allowed while vehicle is moving")
    scene.vehicle.reset_motion()
    scene.toggle_vehicle()
    _check(not scene.player.in_vehicle and scene.player.visible, "Player did not exit into the world")
    var start: Vector3 = scene.player.position
    Input.action_press("ui_up")
    for frame in range(90):
        await physics_frame
    Input.action_release("ui_up")
    _check(scene.player.position.distance_to(start) > 4.0, "On-foot movement did not advance")
    _check(not scene.player.try_enter_vehicle(), "Distant vehicle could be entered")
    Input.action_press("ui_down")
    for frame in range(90):
        await physics_frame
    Input.action_release("ui_down")
    for frame in range(20):
        await physics_frame
    scene.toggle_vehicle()
    _check(scene.player.in_vehicle and not scene.player.visible, "Player could not re-enter the nearby stopped car")
    var mileage: float = scene.vehicle.odometer_m
    Input.action_press("ui_up")
    for frame in range(100):
        await physics_frame
    Input.action_release("ui_up")
    _check(scene.vehicle.odometer_m - mileage > 6.0, "Driving input did not move the car")
    scene.vehicle.reset_motion()
    scene.toggle_vehicle()
    _check(not scene.player.in_vehicle, "Could not park and exit before distant streaming test")
    var parked: Dictionary = scene.get_snapshot().car
    var destination: Array = scene.roads.manifest.parish_anchors.Hanover.road_position
    scene.player.position = scene.roads.world_to_local(float(destination[0]), float(destination[2]), float(destination[1]) + 0.35)
    scene._rebase(float(destination[0]), float(destination[2]))
    scene._settle_spawn = true
    scene._refresh_streamers()
    await _wait_ready(scene)
    for frame in range(30):
        await physics_frame
    var frozen: Dictionary = scene.get_snapshot().car
    for field in ["easting", "northing", "elevation"]:
        _check(absf(float(frozen[field]) - float(parked[field])) < 0.001, "Distant parked car changed " + field)
    scene.goto_parish("St. Mary")
    await _wait_ready(scene)
    var snapshot: Dictionary = scene.get_snapshot()
    var canonical_x := float(snapshot.car.easting)
    var canonical_n := float(snapshot.car.northing)
    scene._rebase(-160000.25, -54000.50)
    var shifted: Dictionary = scene.get_snapshot()
    _check(absf(float(shifted.car.easting) - canonical_x) < 0.02 and absf(float(shifted.car.northing) - canonical_n) < 0.02, "Origin shift changed canonical saved coordinates")
    scene.restore_snapshot(snapshot)
    _check(absf(float(scene.get_snapshot().car.easting) - canonical_x) < 0.001, "Restoring a save changed global position")
    var path := "user://yardman/tests/save.json"
    for suffix in ["", ".bak", ".tmp"]:
        if FileAccess.file_exists(path + suffix):
            DirAccess.remove_absolute(path + suffix)
    _check(SaveScript.save_file(path, snapshot) == OK, "First save failed")
    var saved: Dictionary = SaveScript.load_file(path)
    _check(not saved.is_empty() and absf(float(saved.car.easting) - canonical_x) < 0.001, "Save round trip failed")
    var next := snapshot.duplicate(true)
    next.car.easting = float(next.car.easting) + 20.0
    _check(SaveScript.save_file(path, next) == OK, "Second save failed")
    var broken := FileAccess.open(path, FileAccess.WRITE)
    broken.store_string("{\"payload\":null}")
    broken.close()
    var fallback: Dictionary = SaveScript.load_file(path)
    _check(not fallback.is_empty() and absf(float(fallback.car.easting) - canonical_x) < 0.001, "Corrupt save did not recover its backup")
    var invalid := snapshot.duplicate(true)
    invalid.car.easting = NAN
    _check(SaveScript.save_file(path, invalid) == ERR_INVALID_DATA, "Non-finite world coordinates were saved")
    var controls = scene.touch
    controls.apply_settings({"steering_mode": "Buttons"})
    for item in [[0, "gas"], [1, "left"]]:
        var event := InputEventScreenTouch.new()
        event.index = item[0]
        event.pressed = true
        event.position = controls._zone_rect(item[1]).get_center()
        controls._input(event)
    _check(controls.throttle() == 1.0 and controls.steering() == -1.0, "Two-finger steering/throttle conflict")
    var released := InputEventScreenTouch.new()
    released.index = 1
    released.pressed = false
    controls._input(released)
    _check(controls.throttle() == 1.0 and controls.steering() == 0.0, "Releasing one finger cleared the other")
    controls._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
    _check(controls.fingers.is_empty(), "Controls remained stuck after focus loss")
    for quality in ["Performance", "Balanced", "Quality", "Ultra", "Custom"]:
        scene.set_quality(quality, {"trees": 99, "road_radius": 1, "terrain_radius": 1})
        _check(scene.visuals.quality == quality, "Quality selection failed")
    _check(int(scene.visuals.settings().trees) == 99, "Custom density was ignored")
    print("YARDMAN_GAMEPLAY_TEST %s parishes=14 walk=1 drive=1 enter_exit=1 save_backup=1 multitouch=1" % ("PASS" if failures == 0 else "FAIL"))
    scene.queue_free()
    await process_frame
    quit(0 if failures == 0 else 1)
