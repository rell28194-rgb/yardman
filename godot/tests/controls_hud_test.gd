extends SceneTree

const ControlsScript = preload("res://scripts/touch_controls.gd")
const HUDScript = preload("res://scripts/hud.gd")
const PlayerScript = preload("res://scripts/player_controller.gd")
var failures := 0
var interaction_count := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("CONTROLS_HUD_TEST: " + message)

func _press(controls, index: int, point: Vector2) -> void:
    var event := InputEventScreenTouch.new()
    event.index = index
    event.pressed = true
    event.position = point
    controls._input(event)

func _drag(controls, index: int, point: Vector2, relative: Vector2) -> void:
    var event := InputEventScreenDrag.new()
    event.index = index
    event.position = point
    event.relative = relative
    controls._input(event)

func _release(controls, index: int) -> void:
    var event := InputEventScreenTouch.new()
    event.index = index
    controls._input(event)

func _run() -> void:
    root.size = Vector2i(1280, 720)
    var controls = ControlsScript.new()
    root.add_child(controls)
    await process_frame
    _check(controls.settings.steering_mode == "Stick", "Newest default steering must be Stick")
    controls.interaction_requested.connect(func() -> void: interaction_count += 1)
    var stick: Vector2 = controls._center("stick")
    _press(controls, 0, stick)
    _drag(controls, 0, stick + Vector2(-80.0, 0.0), Vector2(-80.0, 0.0))
    _press(controls, 1, controls._center("gas"))
    _press(controls, 2, Vector2(700, 330))
    _drag(controls, 2, Vector2(736, 342), Vector2(36, 12))
    _check(controls.throttle() == 1.0 and controls.steering() < -0.99, "Gas and analog steering were not independent")
    _check(controls.consume_look().is_equal_approx(Vector2(36, 12)), "Third finger did not look independently")
    _release(controls, 0)
    _check(controls.throttle() == 1.0 and controls.steering() == 0.0, "Releasing stick cleared the gas finger")
    _press(controls, 3, controls._center("brake"))
    _check(controls.brake() == 1.0 and controls.throttle() == 1.0, "Brake must be a separate positive channel")
    controls.clear_input()
    _press(controls, 0, controls._center("reverse"))
    _release(controls, 0)
    _press(controls, 1, controls._center("gas"))
    _check(controls.throttle() == -1.0, "Reverse selector did not change pedal direction")
    controls.driving = false
    _check(controls.fingers.is_empty() and not controls.reverse_selected, "Vehicle transition kept old pedal ownership")
    var origin := Vector2(170, 590)
    _press(controls, 0, origin)
    _drag(controls, 0, origin + Vector2(2, 0), Vector2(2, 0))
    _check(controls.movement_vector() == Vector2.ZERO, "Deadzone allowed accidental movement")
    _drag(controls, 0, origin + Vector2(100, -100), Vector2(98, -100))
    _press(controls, 1, controls._center("sprint"))
    var movement: Vector2 = controls.movement_vector()
    _check(is_equal_approx(movement.length(), 1.0) and movement.x > 0.6 and movement.y < -0.6, "Walking analog diagonal magnitude is wrong")
    _check(controls.sprint_held() and controls.throttle() == 0.0, "Sprint/walk inputs leaked into driving")
    controls._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
    _check(controls.fingers.is_empty() and controls.movement_vector() == Vector2.ZERO, "Focus loss left stuck controls")
    controls.driving = true
    controls.apply_settings({"steering_mode": "Buttons"})
    _press(controls, 0, controls._center("left"))
    _press(controls, 1, controls._center("gas"))
    _check(controls.steering() == -1.0 and controls.throttle() == 1.0, "Optional buttons mode failed")
    controls.apply_settings({"steering_mode": "Wheel"})
    stick = controls._center("stick")
    _press(controls, 0, stick + Vector2(65, -10))
    _check(controls.steering() > 0.75, "Optional wheel mode failed")
    controls.apply_settings({"steering_mode": "Stick", "look_sensitivity": 2.0, "invert_y": true})
    _press(controls, 2, Vector2(720, 300))
    _drag(controls, 2, Vector2(730, 315), Vector2(10, 15))
    _check(controls.consume_look().is_equal_approx(Vector2(20, -30)), "Sensitivity/invert settings were ignored")
    controls.input_enabled = false
    _press(controls, 0, controls._center("gas"))
    _check(controls.fingers.is_empty() and controls.throttle() == 0.0, "Blocked UI accepted controls")
    controls.input_enabled = true
    controls.layout_editing = true
    _press(controls, 0, controls._center("gas"))
    _drag(controls, 0, Vector2(970, 610), Vector2(-240, 2))
    _check(controls.throttle() == 0.0, "Editing layout drove the car")
    var settings: Dictionary = controls.get_settings()
    _check(settings.positions.has("gas") and absf(float(settings.positions.gas[0]) - 970.0 / 1280.0) < 0.001, "Layout position was not normalized/persistable")
    controls.layout_editing = false
    controls.clear_input()
    var hud = HUDScript.new()
    hud.configure(["St. Mary", "Kingston", "Hanover"], ["Performance", "Balanced", "Quality", "Ultra", "Custom"])
    root.add_child(hud)
    hud.attach_controls(controls)
    hud.set_status({"parish": "Hanover", "ready": true, "can_interact": true, "driving": true, "speed_kmh": 60.0})
    _check(hud.parish_menu.item_count == 3 and hud.parish_menu.get_item_text(hud.parish_menu.selected) == "Hanover", "HUD travel state did not synchronize")
    _press(controls, 0, controls._center("gas"))
    hud.set_menu_open(true)
    _check(hud.menu_open and not controls.input_enabled and controls.fingers.is_empty(), "Settings drawer did not block and release controls")
    _press(controls, 1, controls._center("gas"))
    _check(controls.throttle() == 0.0, "Settings drawer leaked a pedal press")
    hud.set_menu_open(false)
    _check(controls.input_enabled, "Closing settings did not restore controls")
    var clipped: PackedVector2Array = hud._clip_circle(Vector2(-100, 0), Vector2(100, 0), 50.0)
    _check(clipped.size() == 2 and clipped[0].is_equal_approx(Vector2(-50, 0)) and clipped[1].is_equal_approx(Vector2(50, 0)), "Radar roads cross its circular boundary")
    var player = PlayerScript.new()
    var car := CharacterBody3D.new()
    root.add_child(car)
    player.configure({"body": car, "occupied": true, "speed_mps": 0.0})
    root.add_child(player)
    player._set_occupied(false)
    player._animate(0.2, 4.0)
    _check(absf(player._left_leg.rotation.x) > 0.05 and is_equal_approx(player._left_leg.rotation.x, -player._right_leg.rotation.x), "Walking limbs were not animated in opposition")
    player.reduced_motion = true
    player._animate(0.1, 4.0)
    _check(player._visual.position.y == 0.0, "Reduced motion kept body bobbing")
    _check(player.can_enter_vehicle(), "Contextual nearby vehicle helper failed")
    player.position = Vector3(8, 0, 0)
    _check(not player.can_enter_vehicle(), "Contextual helper offered a distant car")
    print("YARDMAN_CONTROLS_HUD_TEST %s analog=1 pedals=1 sprint=1 look=1 menu_block=1 layout=1 animation=1" % ("PASS" if failures == 0 else "FAIL"))
    hud.queue_free()
    controls.queue_free()
    player.queue_free()
    car.queue_free()
    await process_frame
    quit(0 if failures == 0 else 1)
