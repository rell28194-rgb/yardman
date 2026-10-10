extends Control
class_name YardmanTouchControls

signal interaction_requested
signal reverse_changed(selected: bool)
signal settings_changed(settings: Dictionary)

const CREAM := Color(0.95, 0.93, 0.85)
const GREEN := Color(0.39, 0.72, 0.51)
const GOLD := Color(0.91, 0.71, 0.36)
const DEFAULT_SETTINGS := {
    "steering_mode": "Stick", "stick_deadzone": 0.12,
    "look_sensitivity": 1.0, "invert_y": false,
    "button_scale": 1.0, "button_opacity": 0.8,
    "reduced_motion": false, "positions": {}
}

var driving := true:
    set(value):
        if driving != value:
            clear_input()
            reverse_selected = false
        driving = value
        queue_redraw()
var input_enabled := true:
    set(value):
        input_enabled = value
        if not value:
            clear_input()
        queue_redraw()
var interaction_enabled := true
var layout_editing := false
var reverse_selected := false
var fingers: Dictionary = {}
var look_delta := Vector2.ZERO
var settings: Dictionary = DEFAULT_SETTINGS.duplicate(true)
var _stick_origin := Vector2.ZERO
var _stick_position := Vector2.ZERO
var _stick_owner := -999
var _touch_seen := false
var _mouse_look := false

func _ready() -> void:
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    _touch_seen = DisplayServer.is_touchscreen_available()

func _process(_delta: float) -> void:
    queue_redraw()

func is_touch_mode() -> bool:
    return _touch_seen or layout_editing

func get_settings() -> Dictionary:
    return settings.duplicate(true)

func apply_settings(value: Dictionary) -> void:
    settings = DEFAULT_SETTINGS.duplicate(true)
    settings.merge(value, true)
    if not str(settings.steering_mode) in ["Stick", "Buttons", "Wheel"]:
        settings.steering_mode = "Stick"
    settings.stick_deadzone = clampf(float(settings.stick_deadzone), 0.0, 0.45)
    settings.look_sensitivity = clampf(float(settings.look_sensitivity), 0.25, 2.5)
    settings.button_scale = clampf(float(settings.button_scale), 0.75, 1.4)
    settings.button_opacity = clampf(float(settings.button_opacity), 0.15, 1.0)
    if not settings.positions is Dictionary:
        settings.positions = {}
    clear_input()
    queue_redraw()

func clear_input() -> void:
    fingers.clear()
    _stick_owner = -999
    _stick_position = Vector2.ZERO
    _mouse_look = false
    look_delta = Vector2.ZERO

func _notification(what: int) -> void:
    if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_APPLICATION_PAUSED:
        clear_input()

func _input(event: InputEvent) -> void:
    if not input_enabled:
        return
    if event is InputEventScreenTouch:
        _touch_seen = true
        if event.pressed:
            _press(event.index, event.position)
        else:
            _release(event.index)
    elif event is InputEventScreenDrag:
        _drag(event.index, event.position, event.relative)
    elif event is InputEventMouseButton and event.device >= 0:
        if event.button_index == MOUSE_BUTTON_RIGHT:
            _mouse_look = event.pressed
    elif event is InputEventMouseMotion and event.device >= 0 and _mouse_look:
        look_delta += event.relative * float(settings.look_sensitivity) * Vector2(1.0, -1.0 if bool(settings.invert_y) else 1.0)

func _press(index: int, point: Vector2) -> void:
    var zone := _zone_at(point)
    if zone.is_empty():
        return
    if zone == "move":
        if _stick_owner != -999:
            return
        _stick_owner = index
        # Walking floats where the thumb lands; driving can be grabbed off-centre.
        _stick_origin = _center("stick") if driving else point
        _stick_position = point
    fingers[index] = {"zone": zone, "position": point}
    if layout_editing:
        return
    if zone == "interact" and interaction_enabled:
        interaction_requested.emit()
    elif zone == "reverse" and driving:
        reverse_selected = not reverse_selected
        reverse_changed.emit(reverse_selected)
    queue_redraw()

func _release(index: int) -> void:
    fingers.erase(index)
    if index == _stick_owner:
        _stick_owner = -999
        _stick_position = Vector2.ZERO
    queue_redraw()

func _drag(index: int, point: Vector2, relative: Vector2) -> void:
    if not fingers.has(index):
        return
    var record: Dictionary = fingers[index]
    var zone := str(record.zone)
    if layout_editing and zone != "look":
        var slot := "stick" if zone == "move" else zone
        var dimensions := get_viewport_rect().size
        var radius := _radius(slot)
        var safe := Vector2(clampf(point.x, radius + 16.0, dimensions.x - radius - 16.0), clampf(point.y, radius + 80.0, dimensions.y - radius - 16.0))
        settings.positions[slot] = [safe.x / dimensions.x, safe.y / dimensions.y]
        if zone == "move":
            _stick_origin = safe
            _stick_position = safe
        settings_changed.emit(get_settings())
    elif zone == "move":
        _stick_position = point
    elif zone == "look" and not layout_editing:
        look_delta += relative * float(settings.look_sensitivity) * Vector2(1.0, -1.0 if bool(settings.invert_y) else 1.0)
    record.position = point
    fingers[index] = record

func held(zone: String) -> bool:
    for record in fingers.values():
        if str(record.zone) == zone:
            return true
    return false

func movement_vector() -> Vector2:
    if not input_enabled or driving or layout_editing:
        return Vector2.ZERO
    return _stick_vector()

func _stick_vector() -> Vector2:
    if _stick_owner == -999:
        return Vector2.ZERO
    var value := (_stick_position - _stick_origin) / (_radius("stick") * 0.85)
    var length := minf(value.length(), 1.0)
    var deadzone := float(settings.stick_deadzone)
    if length <= deadzone:
        return Vector2.ZERO
    return value.normalized() * ((length - deadzone) / (1.0 - deadzone))

func sprint_held() -> bool:
    return input_enabled and not driving and not layout_editing and held("sprint")

func throttle() -> float:
    if not input_enabled or not driving or layout_editing or not held("gas"):
        return 0.0
    return -1.0 if reverse_selected else 1.0

func brake() -> float:
    return 1.0 if input_enabled and driving and not layout_editing and held("brake") else 0.0

func handbrake_held() -> bool:
    return input_enabled and driving and not layout_editing and held("handbrake")

func steering() -> float:
    if not input_enabled or not driving or layout_editing:
        return 0.0
    if str(settings.steering_mode) == "Buttons":
        return float(int(held("right")) - int(held("left")))
    if str(settings.steering_mode) == "Wheel" and _stick_owner != -999:
        var arm := _stick_position - _stick_origin
        if arm.length() < 12.0:
            return 0.0
        return clampf(atan2(arm.x, -arm.y) / (PI * 0.55), -1.0, 1.0)
    return _stick_vector().x

func consume_look() -> Vector2:
    var value := look_delta
    look_delta = Vector2.ZERO
    return value

func _zone_at(point: Vector2) -> String:
    if point.y < 82.0:
        return ""
    var zones: Array = ["gas", "brake", "handbrake", "reverse"] if driving else ["sprint"]
    if interaction_enabled:
        zones.append("interact")
    if driving and str(settings.steering_mode) == "Buttons":
        zones.append_array(["left", "right"])
    for zone in zones:
        if point.distance_to(_center(str(zone))) <= _radius(str(zone)) + 10.0:
            return str(zone)
    var viewport_size := get_viewport_rect().size
    if (not driving and point.x < viewport_size.x * 0.46 and point.y > viewport_size.y * 0.48) or (driving and str(settings.steering_mode) != "Buttons" and point.distance_to(_center("stick")) < _radius("stick") * 1.4):
        return "move"
    return "look" if point.x > viewport_size.x * 0.38 else ""

func _center(zone: String) -> Vector2:
    var dimensions := get_viewport_rect().size
    var positions := {
        "stick": Vector2(132.0, dimensions.y - 118.0),
        "left": Vector2(75.0, dimensions.y - 110.0),
        "right": Vector2(190.0, dimensions.y - 110.0),
        "gas": Vector2(dimensions.x - 70.0, dimensions.y - 112.0),
        "brake": Vector2(dimensions.x - 186.0, dimensions.y - 112.0),
        "handbrake": Vector2(dimensions.x - 166.0, dimensions.y - 232.0),
        "reverse": Vector2(dimensions.x - 64.0, dimensions.y - 240.0),
        "sprint": Vector2(dimensions.x - 70.0, dimensions.y - 112.0),
        "interact": Vector2(dimensions.x - 72.0, dimensions.y - 334.0)
    }
    var value: Vector2 = positions.get(zone, Vector2(100.0, dimensions.y - 100.0))
    var custom: Variant = settings.positions.get(zone, [])
    if custom is Array and custom.size() == 2:
        value = Vector2(float(custom[0]) * dimensions.x, float(custom[1]) * dimensions.y)
    return value

func _radius(zone: String) -> float:
    return (76.0 if zone == "stick" else (45.0 if zone in ["gas", "brake", "sprint"] else 32.0)) * float(settings.button_scale)

func _zone_rect(zone: String) -> Rect2:
    var center := _center(zone)
    var radius := _radius(zone)
    return Rect2(center - Vector2.ONE * radius, Vector2.ONE * radius * 2.0)

func _draw() -> void:
    if not is_touch_mode() or not input_enabled:
        return
    var opacity := float(settings.button_opacity)
    var zones: Array = ["gas", "brake", "handbrake", "reverse"] if driving else ["sprint"]
    if interaction_enabled:
        zones.append("interact")
    if driving and str(settings.steering_mode) == "Buttons":
        zones.append_array(["left", "right"])
    else:
        var center := _stick_origin if _stick_owner != -999 else _center("stick")
        var radius := _radius("stick")
        draw_circle(center, radius, Color(0.035, 0.055, 0.05, opacity * 0.55))
        draw_arc(center, radius, 0.0, TAU, 56, Color(CREAM, opacity * 0.45), 1.6, true)
        draw_arc(center, radius * 0.45, 0.0, TAU, 40, Color(CREAM, opacity * 0.18), 1.0, true)
        var thumb := center + _stick_vector() * radius * 0.62
        draw_circle(thumb, radius * 0.29, Color(GREEN if _stick_owner != -999 else CREAM, opacity * 0.65))
        if driving and str(settings.steering_mode) == "Wheel":
            draw_line(center, center + Vector2.UP.rotated(steering() * PI * 0.55) * radius * 0.70, CREAM, 4.0, true)
    for zone_value in zones:
        var zone := str(zone_value)
        var center := _center(zone)
        var radius := _radius(zone)
        var active := held(zone) or (zone == "reverse" and reverse_selected)
        draw_circle(center, radius, Color(0.035, 0.05, 0.047, opacity * (0.85 if active else 0.65)))
        draw_arc(center, radius, 0.0, TAU, 48, Color(GOLD if active else CREAM, opacity * 0.75), 2.0 if active else 1.2, true)
        _glyph(zone, center, radius * 0.43, Color(GOLD if active else CREAM, opacity))
    if layout_editing:
        draw_string(ThemeDB.fallback_font, Vector2(24, 112), "Drag controls to reposition · open Menu when finished", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, CREAM)

func _glyph(zone: String, center: Vector2, size: float, color: Color) -> void:
    var line := 2.5
    if zone == "gas":
        draw_line(center + Vector2(-size * 0.55, size), center + Vector2(0.0, -size), color, line, true)
        draw_line(center + Vector2(0.0, -size), center + Vector2(size * 0.55, size), color, line, true)
        draw_line(center + Vector2(-size * 0.27, 0.0), center + Vector2(size * 0.27, 0.0), color, line, true)
    elif zone == "brake":
        draw_rect(Rect2(center - Vector2.ONE * size * 0.58, Vector2.ONE * size * 1.16), color, false, line)
    elif zone == "handbrake":
        draw_arc(center, size, 0.0, TAU, 24, color, line, true)
        _letter("P", center, int(size * 1.45), color)
    elif zone == "reverse":
        _letter("R" if reverse_selected else "D", center, int(size * 1.5), color)
    elif zone == "interact":
        draw_rect(Rect2(center + Vector2(-size * 0.5, -size), Vector2(size, size * 2.0)), color, false, line)
        var sign_value := -1.0 if driving else 1.0
        draw_line(center - Vector2(size * sign_value, 0.0), center + Vector2(size * sign_value, 0.0), color, line, true)
        draw_line(center + Vector2(size * sign_value, 0.0), center + Vector2(size * 0.35 * sign_value, -size * 0.45), color, line, true)
        draw_line(center + Vector2(size * sign_value, 0.0), center + Vector2(size * 0.35 * sign_value, size * 0.45), color, line, true)
    elif zone == "sprint":
        draw_circle(center + Vector2(size * 0.24, -size * 0.78), size * 0.20, color)
        var torso := center + Vector2(0.0, -size * 0.10)
        draw_line(center + Vector2(size * 0.12, -size * 0.50), torso, color, line, true)
        draw_polyline(PackedVector2Array([torso + Vector2(-size * 0.50, -size * 0.34), torso, torso + Vector2(size * 0.55, size * 0.08)]), color, line, true)
        draw_polyline(PackedVector2Array([torso + Vector2(-size * 0.60, size * 0.75), torso, torso + Vector2(size * 0.45, size * 0.44), torso + Vector2(size * 0.75, size * 0.75)]), color, line, true)
    elif zone in ["left", "right"]:
        var sign_value := -1.0 if zone == "left" else 1.0
        draw_polyline(PackedVector2Array([center + Vector2(-size * 0.5 * sign_value, -size), center + Vector2(size * 0.5 * sign_value, 0), center + Vector2(-size * 0.5 * sign_value, size)]), color, line, true)

func _letter(value: String, center: Vector2, font_size: int, color: Color) -> void:
    var font := ThemeDB.fallback_font
    var extent := font.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
    draw_string(font, center + Vector2(-extent.x * 0.5, font_size * 0.35), value, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
