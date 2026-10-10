extends Control
class_name YardmanHUD

signal travel_requested(parish: String)
signal quality_requested(quality: String)
signal save_requested
signal recover_requested
signal interaction_requested
signal credits_requested
signal menu_toggled(open: bool)

const CREAM := Color(0.95, 0.93, 0.85)
const MUTED := Color(0.70, 0.74, 0.68)
const GREEN := Color(0.39, 0.72, 0.51)
const GOLD := Color(0.91, 0.71, 0.36)
const CHARCOAL := Color(0.045, 0.062, 0.056)

var menu_open := false
var parish_menu: OptionButton
var quality_menu: OptionButton
var _controls
var _status: Dictionary = {"parish": "Jamaica", "speed_kmh": 0.0, "driving": true, "ready": false, "can_interact": false, "message": "", "heading": 0.0, "gear": "D", "time_hour": 9.0}
var _paths: Array = []
var _radar_center := Vector2.ZERO
var _radar_heading := 0.0
var _menu_button: Button
var _interact_button: Button
var _overlay: Control
var _drawer: PanelContainer
var _control_rows: VBoxContainer
var _controls_built := false
var _parishes: Array = []
var _qualities: Array = []
var _settings_widgets: Dictionary = {}

func _ready() -> void:
    set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    theme = _make_theme()
    _menu_button = _button("≡", func() -> void: set_menu_open(not menu_open))
    _menu_button.tooltip_text = "Menu · Escape"
    _menu_button.add_theme_font_size_override("font_size", 30)
    add_child(_menu_button)
    _interact_button = _button("E  Enter vehicle", func() -> void: interaction_requested.emit())
    add_child(_interact_button)
    _make_menu()
    _relayout()
    get_viewport().size_changed.connect(_relayout)
    _populate_options()

func configure(parishes: Array, qualities: Array) -> void:
    _parishes = parishes.duplicate()
    _qualities = qualities.duplicate()
    _populate_options()

func attach_controls(controls) -> void:
    _controls = controls
    _controls.interaction_requested.connect(func() -> void: interaction_requested.emit())
    if is_node_ready():
        _make_controls_settings()

func set_status(value: Dictionary) -> void:
    var previous_parish := str(_status.parish)
    _status.merge(value, true)
    if str(_status.parish) != previous_parish:
        select_parish(str(_status.parish))
    var can_interact := bool(_status.ready) and bool(_status.can_interact)
    if _controls != null:
        _controls.interaction_enabled = can_interact
    if _interact_button != null:
        _interact_button.visible = can_interact and (_controls == null or not _controls.is_touch_mode()) and not menu_open
        _interact_button.text = "E  Leave vehicle" if bool(_status.driving) else "E  Enter vehicle"
    queue_redraw()

func set_radar_paths(paths: Array, center: Vector2, heading: float) -> void:
    _paths = paths
    _radar_center = center
    _radar_heading = heading
    queue_redraw()

func select_parish(value: String) -> void:
    _select(parish_menu, value)

func select_quality(value: String) -> void:
    _select(quality_menu, value)

func _select(menu: OptionButton, value: String) -> void:
    if menu == null:
        return
    for index in range(menu.item_count):
        if menu.get_item_text(index) == value:
            menu.select(index)
            return

func _populate_options() -> void:
    if parish_menu == null:
        return
    parish_menu.clear()
    quality_menu.clear()
    for parish in _parishes:
        parish_menu.add_item(str(parish))
    for quality in _qualities:
        quality_menu.add_item(str(quality))
    select_parish(str(_status.parish))

func set_menu_open(value: bool) -> void:
    menu_open = value
    if _overlay != null:
        _overlay.visible = value
    if _controls != null:
        _controls.layout_editing = false
        _controls.input_enabled = not value
        _controls.clear_input()
        _make_controls_settings()
    if value:
        select_parish(str(_status.parish))
    if _interact_button != null:
        _interact_button.visible = not value and bool(_status.can_interact) and (_controls == null or not _controls.is_touch_mode())
    menu_toggled.emit(value)
    queue_redraw()

func _unhandled_key_input(event: InputEvent) -> void:
    if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_ESCAPE:
        set_menu_open(not menu_open)
        get_viewport().set_input_as_handled()

func _relayout() -> void:
    var dimensions := get_viewport_rect().size
    if _menu_button != null:
        _menu_button.position = Vector2(dimensions.x - 72.0, 18.0)
        _menu_button.size = Vector2(48, 44)
    if _interact_button != null:
        _interact_button.position = Vector2(dimensions.x - 208.0, dimensions.y - 68.0)
        _interact_button.size = Vector2(184, 44)
    if _drawer != null:
        var width := minf(454.0, dimensions.x - 40.0)
        _drawer.position = Vector2(dimensions.x - width - 20.0, 20.0)
        _drawer.size = Vector2(width, dimensions.y - 40.0)
    queue_redraw()

func _make_menu() -> void:
    _overlay = Control.new()
    _overlay.name = "MenuInputBlocker"
    _overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    _overlay.mouse_filter = Control.MOUSE_FILTER_STOP
    _overlay.visible = false
    add_child(_overlay)
    var scrim := ColorRect.new()
    scrim.color = Color(0.0, 0.012, 0.008, 0.55)
    scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    scrim.mouse_filter = Control.MOUSE_FILTER_STOP
    _overlay.add_child(scrim)
    _drawer = PanelContainer.new()
    _drawer.add_theme_stylebox_override("panel", _style(Color(CHARCOAL, 0.97), Color(0.20, 0.29, 0.23), 16, 22))
    _overlay.add_child(_drawer)
    var column := VBoxContainer.new()
    column.add_theme_constant_override("separation", 12)
    _drawer.add_child(column)
    var title_row := HBoxContainer.new()
    column.add_child(title_row)
    var title := _label("YARDMAN", 26, CREAM)
    title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    title_row.add_child(title)
    var close := _button("×", func() -> void: set_menu_open(false))
    close.custom_minimum_size = Vector2(46, 46)
    close.add_theme_font_size_override("font_size", 28)
    title_row.add_child(close)
    var scroll := ScrollContainer.new()
    scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    column.add_child(scroll)
    var rows := VBoxContainer.new()
    rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    rows.add_theme_constant_override("separation", 10)
    scroll.add_child(rows)
    rows.add_child(_label("WORLD", 16, GREEN))
    rows.add_child(_label("Travel across Jamaica", 17, MUTED))
    parish_menu = OptionButton.new()
    parish_menu.custom_minimum_size.y = 46
    parish_menu.focus_mode = Control.FOCUS_NONE
    rows.add_child(parish_menu)
    rows.add_child(_button("Travel to selected parish", func() -> void:
        if parish_menu.selected >= 0:
            var parish := parish_menu.get_item_text(parish_menu.selected)
            set_menu_open(false)
            travel_requested.emit(parish)))
    var actions := HBoxContainer.new()
    actions.add_theme_constant_override("separation", 10)
    rows.add_child(actions)
    var save := _button("Save", func() -> void: save_requested.emit())
    save.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    actions.add_child(save)
    var recover := _button("Recover car", func() -> void:
        set_menu_open(false)
        recover_requested.emit())
    recover.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    actions.add_child(recover)
    rows.add_child(HSeparator.new())
    rows.add_child(_label("GRAPHICS", 16, GREEN))
    quality_menu = OptionButton.new()
    quality_menu.custom_minimum_size.y = 46
    quality_menu.focus_mode = Control.FOCUS_NONE
    quality_menu.item_selected.connect(func(index: int) -> void:
        var quality := quality_menu.get_item_text(index)
        if quality == "Custom":
            set_menu_open(false)
        quality_requested.emit(quality))
    rows.add_child(quality_menu)
    rows.add_child(HSeparator.new())
    rows.add_child(_label("CONTROLS", 16, GREEN))
    _control_rows = VBoxContainer.new()
    _control_rows.add_theme_constant_override("separation", 8)
    rows.add_child(_control_rows)
    _make_controls_settings()
    rows.add_child(HSeparator.new())
    rows.add_child(_label("On foot: left stick moves relative to the camera.\nRight side looks. Hold the runner to sprint.\nDrive: left stick steers, separate gas and brake.\nD / R selects direction; circled P is handbrake.\nKeyboard: WASD / arrows · E · Shift · F5", 15, MUTED))
    rows.add_child(_button("World data & credits", func() -> void:
        set_menu_open(false)
        credits_requested.emit()))

func _make_controls_settings() -> void:
    if _control_rows == null or _controls == null:
        return
    if _controls_built:
        for key in _settings_widgets:
            var widget: Control = _settings_widgets[key]
            if widget is OptionButton:
                _select(widget, str(_controls.settings[key]))
            elif widget is Range:
                widget.set_value_no_signal(float(_controls.settings[key]))
            elif widget is BaseButton:
                widget.set_pressed_no_signal(bool(_controls.settings[key]))
        return
    _controls_built = true
    var mode := OptionButton.new()
    for value in ["Stick", "Buttons", "Wheel"]:
        mode.add_item(value)
    _select(mode, str(_controls.settings.steering_mode))
    mode.custom_minimum_size.y = 42
    mode.item_selected.connect(func(index: int) -> void:
        _change_setting("steering_mode", mode.get_item_text(index)))
    _control_rows.add_child(_label("Vehicle steering", 16, MUTED))
    _control_rows.add_child(mode)
    _settings_widgets.steering_mode = mode
    for item in [["stick_deadzone", "Stick deadzone", 0.0, 0.45, 0.01],
            ["look_sensitivity", "Look sensitivity", 0.25, 2.5, 0.05],
            ["button_scale", "Control size", 0.75, 1.4, 0.05],
            ["button_opacity", "Control opacity", 0.15, 1.0, 0.05]]:
        var key := str(item[0])
        var label := _label(str(item[1]), 16, MUTED)
        _control_rows.add_child(label)
        var slider := HSlider.new()
        slider.min_value = float(item[2])
        slider.max_value = float(item[3])
        slider.step = float(item[4])
        slider.value = float(_controls.settings[key])
        slider.custom_minimum_size.y = 38
        slider.value_changed.connect(func(value: float) -> void: _change_setting(key, value))
        _control_rows.add_child(slider)
        _settings_widgets[key] = slider
    for item in [["invert_y", "Invert vertical look"], ["reduced_motion", "Reduced motion"]]:
        var key := str(item[0])
        var check := CheckBox.new()
        check.text = str(item[1])
        check.button_pressed = bool(_controls.settings[key])
        check.custom_minimum_size.y = 40
        check.toggled.connect(func(value: bool) -> void: _change_setting(key, value))
        _control_rows.add_child(check)
        _settings_widgets[key] = check
    _control_rows.add_child(_button("Reposition touch controls", func() -> void:
        set_menu_open(false)
        _controls.layout_editing = true
        _controls.clear_input()))
    _control_rows.add_child(_button("Reset control layout", func() -> void:
        _change_setting("positions", {})))

func _change_setting(key: String, value: Variant) -> void:
    if _controls == null:
        return
    var current: Dictionary = _controls.get_settings()
    current[key] = value
    _controls.apply_settings(current)
    _controls.settings_changed.emit(_controls.get_settings())

func _button(value: String, action: Callable) -> Button:
    var button := Button.new()
    button.text = value
    button.custom_minimum_size.y = 44
    button.focus_mode = Control.FOCUS_NONE
    button.pressed.connect(action)
    return button

func _label(value: String, font_size: int, color: Color) -> Label:
    var label := Label.new()
    label.text = value
    label.add_theme_font_size_override("font_size", font_size)
    label.add_theme_color_override("font_color", color)
    label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    return label

func _style(background: Color, border: Color, radius: int, padding: int) -> StyleBoxFlat:
    var style := StyleBoxFlat.new()
    style.bg_color = background
    style.border_color = border
    style.set_border_width_all(1)
    style.set_corner_radius_all(radius)
    style.content_margin_left = padding
    style.content_margin_right = padding
    style.content_margin_top = padding
    style.content_margin_bottom = padding
    return style

func _make_theme() -> Theme:
    var result := Theme.new()
    result.default_font_size = 18
    result.set_color("font_color", "Button", CREAM)
    result.set_color("font_hover_color", "Button", Color.WHITE)
    result.set_color("font_pressed_color", "Button", GOLD)
    result.set_stylebox("normal", "Button", _style(Color(0.065, 0.091, 0.079, 0.88), Color(0.25, 0.33, 0.27), 8, 10))
    result.set_stylebox("hover", "Button", _style(Color(0.13, 0.20, 0.16, 0.96), GREEN, 8, 10))
    result.set_stylebox("pressed", "Button", _style(Color(0.10, 0.16, 0.12, 0.98), GOLD, 8, 10))
    result.set_stylebox("normal", "OptionButton", _style(Color(0.065, 0.091, 0.079), Color(0.25, 0.33, 0.27), 8, 10))
    result.set_stylebox("hover", "OptionButton", _style(Color(0.13, 0.20, 0.16), GREEN, 8, 10))
    result.set_stylebox("pressed", "OptionButton", _style(Color(0.10, 0.16, 0.12), GOLD, 8, 10))
    result.set_color("font_color", "OptionButton", CREAM)
    return result

func _draw() -> void:
    var dimensions := get_viewport_rect().size
    _draw_radar(Vector2(95.0, 104.0), 70.0)
    var font := ThemeDB.fallback_font
    _text(str(_status.parish), Vector2(26, 199), 19, CREAM)
    var hour := int(float(_status.time_hour))
    var minute := int(fmod(float(_status.time_hour), 1.0) * 60.0)
    _text("%02d:%02d" % [hour, minute], Vector2(26, 221), 14, MUTED)
    var compass_center := Vector2(dimensions.x * 0.5, 38.0)
    draw_line(compass_center + Vector2(-128, 0), compass_center + Vector2(128, 0), Color(CREAM, 0.25), 1.0, true)
    # Godot yaw is positive west from local -Z (geographic north).
    var heading := -float(_status.heading)
    for tick in range(8):
        var angle := tick * PI / 4.0
        var offset := wrapf(angle - heading, -PI, PI) * 135.0
        if absf(offset) > 124.0:
            continue
        var letters := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        _text(str(letters[tick]), compass_center + Vector2(offset - 7, -9), 14, GOLD if tick == 0 else CREAM)
        draw_line(compass_center + Vector2(offset, -2), compass_center + Vector2(offset, 4), Color(CREAM, 0.70), 1.5, true)
    draw_colored_polygon(PackedVector2Array([compass_center + Vector2(-4, 11), compass_center + Vector2(4, 11), compass_center + Vector2(0, 5)]), GOLD)
    if bool(_status.driving):
        var speed := maxf(0.0, float(_status.speed_kmh))
        var speed_position := Vector2(dimensions.x * 0.5 - 60.0, dimensions.y - 40.0)
        _text("%03d" % int(roundf(speed)), speed_position, 44, CREAM)
        _text("km/h", speed_position + Vector2(84, -2), 14, MUTED)
        _text(str(_status.gear), speed_position + Vector2(120, -1), 22, GOLD)
        draw_line(speed_position + Vector2(-7, 9), speed_position + Vector2(150, 9), Color(CREAM, 0.20), 2.0, true)
        draw_line(speed_position + Vector2(-7, 9), speed_position + Vector2(-7 + minf(speed / 160.0, 1.0) * 157.0, 9), GREEN, 2.0, true)
    var message := "Loading local world…" if not bool(_status.ready) else str(_status.message)
    if not message.is_empty():
        var text_size := font.get_string_size(message, HORIZONTAL_ALIGNMENT_LEFT, -1, 17)
        var message_position := Vector2((dimensions.x - text_size.x) * 0.5, 90.0)
        draw_style_box(_style(Color(CHARCOAL, 0.78), Color(0, 0, 0, 0), 6, 10), Rect2(message_position - Vector2(12, 23), text_size + Vector2(24, 13)))
        _text(message, message_position, 17, CREAM)
    if _controls != null and _controls.is_touch_mode() and bool(_status.can_interact) and not menu_open:
        var point: Vector2 = _controls._center("interact")
        _text("EXIT" if bool(_status.driving) else "ENTER", point + Vector2(-19, -44), 11, CREAM)

func _text(value: String, point: Vector2, font_size: int, color: Color) -> void:
    draw_string(ThemeDB.fallback_font, point + Vector2(1, 2), value, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.01, 0.02, 0.015, 0.75))
    draw_string(ThemeDB.fallback_font, point, value, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)

func _draw_radar(center: Vector2, radius: float) -> void:
    draw_circle(center, radius + 4.0, Color(CHARCOAL, 0.82))
    draw_circle(center, radius, Color(0.15, 0.23, 0.18, 0.88))
    draw_arc(center, radius + 2.0, 0.0, TAU, 64, Color(CREAM, 0.45), 1.2, true)
    var extent := 210.0
    for path in _paths:
        if not path is Array and not path is PackedVector2Array:
            continue
        for index in range(1, path.size()):
            var before := _radar_point(path[index - 1])
            var after := _radar_point(path[index])
            var a := ((before - _radar_center) * (radius / extent)).rotated(_radar_heading)
            var b := ((after - _radar_center) * (radius / extent)).rotated(_radar_heading)
            var clipped := _clip_circle(a, b, radius - 4.0)
            if clipped.size() == 2:
                draw_line(center + clipped[0], center + clipped[1], Color(0.75, 0.79, 0.66, 0.82), 2.4, true)
    draw_colored_polygon(PackedVector2Array([center + Vector2(0, -8), center + Vector2(-5, 5), center + Vector2(0, 2), center + Vector2(5, 5)]), GOLD)
    var north := center + Vector2.UP.rotated(_radar_heading) * (radius - 9.0)
    draw_circle(north, 2.0, GREEN)

func _radar_point(value: Variant) -> Vector2:
    if value is Vector2:
        return value
    if value is Vector3:
        return Vector2(value.x, value.z)
    if value is Array and value.size() >= 2:
        return Vector2(float(value[0]), float(value[2]) if value.size() > 2 else float(value[1]))
    return Vector2.ZERO

func _clip_circle(a: Vector2, b: Vector2, radius: float) -> PackedVector2Array:
    var direction := b - a
    var coefficient := direction.length_squared()
    if coefficient < 0.00001:
        return PackedVector2Array()
    var linear := 2.0 * a.dot(direction)
    var constant := a.length_squared() - radius * radius
    var discriminant := linear * linear - 4.0 * coefficient * constant
    if discriminant < 0.0:
        return PackedVector2Array()
    var root_value := sqrt(discriminant)
    var start := maxf(0.0, (-linear - root_value) / (2.0 * coefficient))
    var finish := minf(1.0, (-linear + root_value) / (2.0 * coefficient))
    if finish < start:
        return PackedVector2Array()
    return PackedVector2Array([a + direction * start, a + direction * finish])
