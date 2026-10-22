extends Node

const TOUCH_SPRINT_ID := -20001
const TOUCH_BRAKE_ID := -20002
const TOUCH_HANDBRAKE_ID := -20003
const LOOK_PIXELS_PER_SECOND := 380.0

var _virtual_actions: Dictionary = {}
var _garage_forced_block := false

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    _configure_actions()
    get_tree().physics_frame.connect(_before_physics_frame)

func _notification(what: int) -> void:
    if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_APPLICATION_PAUSED:
        _release_virtual_actions()
        var game := get_tree().current_scene if get_tree() != null else null
        if game != null:
            _clear_touch_zones(game.get("touch"))

func _configure_actions() -> void:
    _ensure_action("ym_move_forward", 0.18)
    _bind_key("ym_move_forward", KEY_W)
    _bind_key("ym_move_forward", KEY_UP)
    _bind_axis("ym_move_forward", JOY_AXIS_LEFT_Y, -1.0)
    _bind_button("ym_move_forward", JOY_BUTTON_DPAD_UP)

    _ensure_action("ym_move_back", 0.18)
    _bind_key("ym_move_back", KEY_S)
    _bind_key("ym_move_back", KEY_DOWN)
    _bind_axis("ym_move_back", JOY_AXIS_LEFT_Y, 1.0)
    _bind_button("ym_move_back", JOY_BUTTON_DPAD_DOWN)

    _ensure_action("ym_move_left", 0.18)
    _bind_key("ym_move_left", KEY_A)
    _bind_key("ym_move_left", KEY_LEFT)
    _bind_axis("ym_move_left", JOY_AXIS_LEFT_X, -1.0)
    _bind_button("ym_move_left", JOY_BUTTON_DPAD_LEFT)

    _ensure_action("ym_move_right", 0.18)
    _bind_key("ym_move_right", KEY_D)
    _bind_key("ym_move_right", KEY_RIGHT)
    _bind_axis("ym_move_right", JOY_AXIS_LEFT_X, 1.0)
    _bind_button("ym_move_right", JOY_BUTTON_DPAD_RIGHT)

    _ensure_action("ym_drive_accelerate", 0.05)
    _bind_axis("ym_drive_accelerate", JOY_AXIS_TRIGGER_RIGHT, 1.0)
    _ensure_action("ym_drive_reverse", 0.05)
    _bind_axis("ym_drive_reverse", JOY_AXIS_TRIGGER_LEFT, 1.0)

    _ensure_action("ym_look_left", 0.16)
    _bind_key("ym_look_left", KEY_J)
    _bind_axis("ym_look_left", JOY_AXIS_RIGHT_X, -1.0)
    _ensure_action("ym_look_right", 0.16)
    _bind_key("ym_look_right", KEY_L)
    _bind_axis("ym_look_right", JOY_AXIS_RIGHT_X, 1.0)
    _ensure_action("ym_look_up", 0.16)
    _bind_key("ym_look_up", KEY_I)
    _bind_axis("ym_look_up", JOY_AXIS_RIGHT_Y, -1.0)
    _ensure_action("ym_look_down", 0.16)
    _bind_key("ym_look_down", KEY_K)
    _bind_axis("ym_look_down", JOY_AXIS_RIGHT_Y, 1.0)

    _ensure_action("ym_interact", 0.10)
    _bind_key("ym_interact", KEY_E)
    _bind_button("ym_interact", JOY_BUTTON_Y)
    _ensure_action("ym_garage", 0.10)
    _bind_key("ym_garage", KEY_G)
    _bind_button("ym_garage", JOY_BUTTON_X)
    _ensure_action("ym_sprint", 0.10)
    _bind_key("ym_sprint", KEY_SHIFT)
    _bind_button("ym_sprint", JOY_BUTTON_LEFT_STICK)
    _ensure_action("ym_brake", 0.10)
    _bind_key("ym_brake", KEY_CTRL)
    _bind_button("ym_brake", JOY_BUTTON_LEFT_SHOULDER)
    _ensure_action("ym_handbrake", 0.10)
    _bind_key("ym_handbrake", KEY_SPACE)
    _bind_button("ym_handbrake", JOY_BUTTON_A)
    _ensure_action("ym_recover", 0.10)
    _bind_key("ym_recover", KEY_R)
    _bind_button("ym_recover", JOY_BUTTON_B)
    _ensure_action("ym_save", 0.10)
    _bind_key("ym_save", KEY_F5)
    _bind_button("ym_save", JOY_BUTTON_START)

    _ensure_action("ym_garage_confirm", 0.10)
    _bind_key("ym_garage_confirm", KEY_ENTER)
    _bind_button("ym_garage_confirm", JOY_BUTTON_A)
    _ensure_action("ym_garage_cancel", 0.10)
    _bind_key("ym_garage_cancel", KEY_ESCAPE)
    _bind_button("ym_garage_cancel", JOY_BUTTON_B)
    _ensure_action("ym_garage_prev", 0.10)
    _bind_key("ym_garage_prev", KEY_COMMA)
    _bind_button("ym_garage_prev", JOY_BUTTON_DPAD_LEFT)
    _ensure_action("ym_garage_next", 0.10)
    _bind_key("ym_garage_next", KEY_PERIOD)
    _bind_button("ym_garage_next", JOY_BUTTON_DPAD_RIGHT)

func _ensure_action(action: StringName, deadzone: float) -> void:
    if not InputMap.has_action(action):
        InputMap.add_action(action, deadzone)
    else:
        InputMap.action_set_deadzone(action, deadzone)

func _bind_key(action: StringName, physical_keycode: Key) -> void:
    var event := InputEventKey.new()
    event.physical_keycode = physical_keycode
    if not InputMap.action_has_event(action, event):
        InputMap.action_add_event(action, event)

func _bind_button(action: StringName, button: JoyButton) -> void:
    var event := InputEventJoypadButton.new()
    event.button_index = button
    if not InputMap.action_has_event(action, event):
        InputMap.action_add_event(action, event)

func _bind_axis(action: StringName, axis: JoyAxis, direction: float) -> void:
    var event := InputEventJoypadMotion.new()
    event.axis = axis
    event.axis_value = direction
    if not InputMap.action_has_event(action, event):
        InputMap.action_add_event(action, event)

func _input(event: InputEvent) -> void:
    if event is InputEventKey and (not event.pressed or event.echo):
        return
    if event is InputEventJoypadButton and not event.pressed:
        return
    var game := get_tree().current_scene
    if game == null:
        return
    if _garage_open():
        if event.is_action_pressed("ym_garage") or event.is_action_pressed("ym_garage_cancel"):
            set_garage_open(false)
        elif event.is_action_pressed("ym_garage_prev"):
            _garage_step(-1)
        elif event.is_action_pressed("ym_garage_next"):
            _garage_step(1)
        elif event.is_action_pressed("ym_garage_confirm"):
            _garage_apply()
        else:
            return
        _sync_garage_block(game)
        get_viewport().set_input_as_handled()
        return
    if _runtime_blocked(game):
        return
    if event.is_action_pressed("ym_interact"):
        if game.has_method("toggle_vehicle"):
            game.call("toggle_vehicle")
    elif event.is_action_pressed("ym_garage"):
        if not set_garage_open(true):
            return
        _sync_garage_block(game)
    elif event.is_action_pressed("ym_recover"):
        if game.has_method("goto_parish"):
            game.call("goto_parish", str(game.get("current_parish")))
    elif event.is_action_pressed("ym_save"):
        if game.has_method("save_game"):
            game.call("save_game")
    else:
        return
    get_viewport().set_input_as_handled()

func _before_physics_frame() -> void:
    var game := get_tree().current_scene
    if game == null:
        _release_virtual_actions()
        return
    _sync_garage_block(game)
    var touch = game.get("touch")
    if _garage_open() or _runtime_blocked(game):
        _release_virtual_actions()
        _clear_touch_zones(touch)
        return
    var player = game.get("player")
    if player == null:
        _release_virtual_actions()
        _clear_touch_zones(touch)
        return
    var driving := bool(player.get("in_vehicle"))
    var forward := Input.get_action_strength("ym_move_forward")
    var back := Input.get_action_strength("ym_move_back")
    if driving:
        forward = maxf(forward, Input.get_action_strength("ym_drive_accelerate"))
        back = maxf(back, Input.get_action_strength("ym_drive_reverse"))
    _set_virtual_action("ui_up", forward)
    _set_virtual_action("ui_down", back)
    _set_virtual_action("ui_left", Input.get_action_strength("ym_move_left"))
    _set_virtual_action("ui_right", Input.get_action_strength("ym_move_right"))
    _set_touch_zone(touch, TOUCH_SPRINT_ID, "sprint", not driving and Input.is_action_pressed("ym_sprint"))
    _set_touch_zone(touch, TOUCH_BRAKE_ID, "brake", driving and Input.is_action_pressed("ym_brake"))
    _set_touch_zone(touch, TOUCH_HANDBRAKE_ID, "handbrake", driving and Input.is_action_pressed("ym_handbrake"))
    _inject_look(touch)

func _runtime_blocked(game: Node) -> bool:
    var hud = game.get("hud")
    if hud != null and bool(hud.get("menu_open")):
        return true
    var touch = game.get("touch")
    if touch != null and bool(touch.get("layout_editing")):
        return true
    var app_active = game.get("_app_active")
    return app_active is bool and not bool(app_active)

func _set_virtual_action(action: StringName, strength: float) -> void:
    strength = clampf(strength, 0.0, 1.0)
    if strength > 0.01:
        Input.action_press(action, strength)
        _virtual_actions[action] = true
    elif _virtual_actions.has(action):
        Input.action_release(action)
        _virtual_actions.erase(action)

func _release_virtual_actions() -> void:
    for action in _virtual_actions.keys():
        Input.action_release(action)
    _virtual_actions.clear()

func _set_touch_zone(touch, synthetic_id: int, zone: String, active: bool) -> void:
    if touch == null:
        return
    var raw = touch.get("fingers")
    if not raw is Dictionary:
        return
    var fingers: Dictionary = raw
    var changed := false
    if active:
        if not fingers.has(synthetic_id) or str(fingers[synthetic_id].get("zone", "")) != zone:
            fingers[synthetic_id] = {"zone": zone, "position": Vector2.ZERO}
            changed = true
    elif fingers.has(synthetic_id):
        fingers.erase(synthetic_id)
        changed = true
    if changed:
        touch.set("fingers", fingers)
        if touch.has_method("queue_redraw"):
            touch.call("queue_redraw")

func _clear_touch_zones(touch) -> void:
    if touch == null:
        return
    var raw = touch.get("fingers")
    if not raw is Dictionary:
        return
    var fingers: Dictionary = raw
    var changed := false
    for synthetic_id in [TOUCH_SPRINT_ID, TOUCH_BRAKE_ID, TOUCH_HANDBRAKE_ID]:
        if fingers.has(synthetic_id):
            fingers.erase(synthetic_id)
            changed = true
    if changed:
        touch.set("fingers", fingers)
        if touch.has_method("queue_redraw"):
            touch.call("queue_redraw")

func _inject_look(touch) -> void:
    if touch == null:
        return
    var look_x := Input.get_action_strength("ym_look_right") - Input.get_action_strength("ym_look_left")
    var look_y := Input.get_action_strength("ym_look_down") - Input.get_action_strength("ym_look_up")
    if absf(look_x) < 0.001 and absf(look_y) < 0.001:
        return
    var settings_raw = touch.get("settings")
    var sensitivity := 1.0
    var invert_y := false
    if settings_raw is Dictionary:
        sensitivity = clampf(float(settings_raw.get("look_sensitivity", 1.0)), 0.25, 2.5)
        invert_y = bool(settings_raw.get("invert_y", false))
    if invert_y:
        look_y = -look_y
    var raw_delta = touch.get("look_delta")
    var look_delta := raw_delta if raw_delta is Vector2 else Vector2.ZERO
    look_delta += Vector2(look_x, look_y) * LOOK_PIXELS_PER_SECOND * get_physics_process_delta_time() * sensitivity
    touch.set("look_delta", look_delta)

func set_garage_open(value: bool) -> bool:
    var garage := get_node_or_null("/root/VehicleGarage")
    if garage == null:
        return false
    var panel = garage.get("_panel")
    if not panel is Control:
        return false
    panel.visible = value
    if value:
        var game := get_tree().current_scene
        if game != null:
            var touch = game.get("touch")
            if touch != null and touch.has_method("clear_input"):
                touch.call("clear_input")
        _release_virtual_actions()
    return true

func _garage_open() -> bool:
    var garage := get_node_or_null("/root/VehicleGarage")
    if garage == null:
        return false
    var panel = garage.get("_panel")
    return panel is Control and panel.visible

func _garage_step(direction: int) -> void:
    var garage := get_node_or_null("/root/VehicleGarage")
    if garage == null:
        return
    var options = garage.get("_options")
    if not options is OptionButton or options.item_count <= 0:
        return
    var index := options.selected
    if index < 0:
        index = 0
    else:
        index = posmod(index + direction, options.item_count)
    options.select(index)

func _garage_apply() -> void:
    var garage := get_node_or_null("/root/VehicleGarage")
    if garage != null and garage.has_method("_apply_selected"):
        garage.call("_apply_selected")

func _sync_garage_block(game: Node) -> void:
    var hud = game.get("hud")
    if hud == null:
        return
    var open := _garage_open()
    if open:
        if _garage_forced_block:
            return
        var overlay = hud.get("_overlay")
        var real_menu_open := bool(hud.get("menu_open")) and overlay is Control and overlay.visible
        if not real_menu_open:
            hud.set("menu_open", true)
            _garage_forced_block = true
    elif _garage_forced_block:
        var overlay = hud.get("_overlay")
        if not (overlay is Control and overlay.visible):
            hud.set("menu_open", false)
        _garage_forced_block = false
