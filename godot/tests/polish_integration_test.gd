extends SceneTree

var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(value: bool, message: String) -> void:
    if not value:
        failures += 1
        push_error("POLISH_INTEGRATION_TEST: " + message)

func _ready_scene(scene) -> bool:
    for frame in range(2400):
        await physics_frame
        if scene.world_ready and scene.car.is_on_floor():
            return true
    return false

func _run() -> void:
    var scene = load("res://main.tscn").instantiate()
    root.add_child(scene)
    scene.goto_parish("St. Mary")
    _check(await _ready_scene(scene), "Streamed spawn never became playable")
    _check(scene.get_node_or_null("SeaLevel") == null, "Infinite unregistered ocean still exists")
    _check(scene.hud != null and scene.camera.near >= 0.5, "Integrated HUD or road depth precision missing")
    var controls = scene.touch
    var original_settings: Dictionary = controls.get_settings()
    controls.apply_settings({"steering_mode": "Stick", "look_sensitivity": 1.5})
    var saved: Dictionary = scene.get_snapshot()
    scene.restore_snapshot(saved)
    _check(float(controls.settings.look_sensitivity) == 1.5, "Restoring world progress overwrote input preferences")
    _check(await _ready_scene(scene), "Restore did not recover collision residency")
    scene.vehicle.reset_motion()
    scene.toggle_vehicle()
    _check(not scene.player.in_vehicle, "Context interaction did not exit the stopped car")
    var begin: Vector3 = scene.player.position
    var thumb := Vector2(170, 620)
    controls._press(41, thumb)
    controls._drag(41, thumb + Vector2(0, -80), Vector2(0, -80))
    for frame in range(60):
        await physics_frame
    controls._release(41)
    _check(scene.player.position.distance_to(begin) > 2.4, "Main scene ignored the walking joystick")
    scene.hud.set_menu_open(true)
    var paused: Vector3 = scene.player.position
    Input.action_press("ui_up")
    for frame in range(45):
        await physics_frame
    Input.action_release("ui_up")
    _check(scene.player.position.distance_to(paused) < 0.01 and controls.fingers.is_empty(), "Menu allowed movement or retained touch input")
    scene.hud.set_menu_open(false)
    scene.goto_parish("St. Ann")
    _check(await _ready_scene(scene), "North-coast spawn failed after origin shift")
    var world: PackedFloat64Array = scene.roads.local_to_world(scene.car.position)
    var surface: Dictionary = scene.roads.road_surface_at(world[0], world[2])
    _check(bool(surface.get("found", false)), "Source-road spawn failed the persistent surface query")
    for frame in range(20):
        await physics_frame
    _check(scene.vehicle.on_road, "Main scene never updated the vehicle's road grip")
    controls.apply_settings({"steering_mode": "Stick", "button_opacity": 0.66})
    scene._save_preferences()
    var preference = JSON.parse_string(FileAccess.get_file_as_string(scene.SETTINGS_PATH))
    _check(preference is Dictionary and preference.has("controls") and not preference.has("car"), "Controls are not saved separately from world progress")
    controls.apply_settings({})
    scene._load_preferences()
    _check(absf(float(controls.settings.button_opacity) - 0.66) < 0.001, "Control settings did not persist")
    controls.apply_settings(original_settings)
    scene._save_preferences()
    print("YARDMAN_POLISH_INTEGRATION_TEST %s joystick=1 menu_pause=1 source_road_grip=1 preferences=1" % ("PASS" if failures == 0 else "FAIL"))
    scene.queue_free()
    await process_frame
    quit(0 if failures == 0 else 1)

