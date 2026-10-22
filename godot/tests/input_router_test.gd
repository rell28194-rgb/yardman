extends SceneTree

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("INPUT_ROUTER: " + message)
    quit(1)

func _has_key(action: StringName, key: Key) -> bool:
    for event in InputMap.action_get_events(action):
        if event is InputEventKey and event.physical_keycode == key:
            return true
    return false

func _has_button(action: StringName, button: JoyButton) -> bool:
    for event in InputMap.action_get_events(action):
        if event is InputEventJoypadButton and event.button_index == button:
            return true
    return false

func _has_axis(action: StringName, axis: JoyAxis, direction: float) -> bool:
    for event in InputMap.action_get_events(action):
        if event is InputEventJoypadMotion and event.axis == axis and signf(event.axis_value) == signf(direction):
            return true
    return false

func _expect(condition: bool, message: String) -> bool:
    if condition:
        return true
    _fail(message)
    return false

func _run() -> void:
    var err := change_scene_to_file("res://main.tscn")
    if err != OK:
        _fail("main scene failed to load: %s" % err)
        return
    for _i in range(30):
        await process_frame
    var router := root.get_node_or_null("InputRouter")
    if router == null:
        _fail("InputRouter autoload missing")
        return

    if not _expect(_has_axis("ym_move_left", JOY_AXIS_LEFT_X, -1.0) and _has_axis("ym_move_right", JOY_AXIS_LEFT_X, 1.0), "left-stick steering mapping missing"):
        return
    if not _expect(_has_axis("ym_move_forward", JOY_AXIS_LEFT_Y, -1.0) and _has_axis("ym_move_back", JOY_AXIS_LEFT_Y, 1.0), "left-stick movement mapping missing"):
        return
    if not _expect(_has_axis("ym_drive_accelerate", JOY_AXIS_TRIGGER_RIGHT, 1.0) and _has_axis("ym_drive_reverse", JOY_AXIS_TRIGGER_LEFT, 1.0), "analog trigger driving mapping missing"):
        return
    if not _expect(_has_axis("ym_look_left", JOY_AXIS_RIGHT_X, -1.0) and _has_axis("ym_look_right", JOY_AXIS_RIGHT_X, 1.0) and _has_axis("ym_look_up", JOY_AXIS_RIGHT_Y, -1.0) and _has_axis("ym_look_down", JOY_AXIS_RIGHT_Y, 1.0), "right-stick camera mapping missing"):
        return
    if not _expect(_has_key("ym_look_left", KEY_J) and _has_key("ym_look_right", KEY_L) and _has_key("ym_look_up", KEY_I) and _has_key("ym_look_down", KEY_K), "keyboard camera mapping missing"):
        return
    if not _expect(_has_key("ym_interact", KEY_E) and _has_button("ym_interact", JOY_BUTTON_Y), "interaction mapping missing"):
        return
    if not _expect(_has_key("ym_garage", KEY_G) and _has_button("ym_garage", JOY_BUTTON_X), "garage mapping missing"):
        return
    if not _expect(_has_key("ym_sprint", KEY_SHIFT) and _has_button("ym_sprint", JOY_BUTTON_LEFT_STICK), "sprint mapping missing"):
        return
    if not _expect(_has_key("ym_brake", KEY_CTRL) and _has_button("ym_brake", JOY_BUTTON_LEFT_SHOULDER), "service-brake mapping missing"):
        return
    if not _expect(_has_key("ym_handbrake", KEY_SPACE) and _has_button("ym_handbrake", JOY_BUTTON_A), "handbrake mapping missing"):
        return
    if not _expect(_has_key("ym_recover", KEY_R) and _has_button("ym_recover", JOY_BUTTON_B), "recovery mapping missing"):
        return
    if not _expect(_has_key("ym_save", KEY_F5) and _has_button("ym_save", JOY_BUTTON_START), "save mapping missing"):
        return

    var game := current_scene
    var garage := root.get_node_or_null("VehicleGarage")
    if game == null or garage == null:
        _fail("runtime scene or garage unavailable")
        return
    var panel = garage.get("_panel")
    if not panel is Control:
        _fail("garage panel unavailable")
        return
    if not bool(router.call("set_garage_open", true)):
        _fail("garage could not be opened through input router")
        return
    await physics_frame
    var hud = game.get("hud")
    if not panel.visible or hud == null or not bool(hud.get("menu_open")):
        _fail("garage did not pause gameplay input")
        return
    if not bool(router.call("set_garage_open", false)):
        _fail("garage could not be closed through input router")
        return
    await physics_frame
    var overlay = hud.get("_overlay")
    if panel.visible:
        _fail("garage remained visible after close")
        return
    if overlay is Control and not overlay.visible and bool(hud.get("menu_open")):
        _fail("garage gameplay block was not released")
        return

    print("YARDMAN_INPUT_ROUTER_PASS keyboard=true dualsense=true analog=true garage=true")
    quit(0)
