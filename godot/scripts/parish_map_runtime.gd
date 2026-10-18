extends CanvasLayer
class_name YardmanParishMapRuntime

const CanvasScript = preload("res://scripts/parish_map_canvas.gd")

var _button: Button
var _overlay: Control
var _canvas: Control
var _open := false

func _ready() -> void:
    layer = 80
    _build_ui()
    var runtime := _parish_runtime()
    if runtime != null:
        if runtime.has_signal("parish_changed"):
            runtime.connect("parish_changed", Callable(self, "_on_parish_changed"))
        if runtime.has_signal("parish_data_reloaded"):
            runtime.connect("parish_data_reloaded", Callable(self, "_on_parish_data_reloaded"))
    call_deferred("_refresh_data")

func is_open() -> bool:
    return _open

func set_map_open(value: bool) -> void:
    if _open == value:
        return
    _open = value
    if _overlay != null:
        _overlay.visible = value
    if _button != null:
        _button.visible = not value
    if value:
        _refresh_data()
    _set_gameplay_input_enabled(not value)

func _unhandled_key_input(event: InputEvent) -> void:
    if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_M:
        set_map_open(not _open)
        get_viewport().set_input_as_handled()

func _build_ui() -> void:
    _button = Button.new()
    _button.name = "ParishMapButton"
    _button.text = "MAP"
    _button.position = Vector2(24.0, 238.0)
    _button.size = Vector2(82.0, 40.0)
    _button.focus_mode = Control.FOCUS_NONE
    _button.tooltip_text = "Parish map · M"
    _button.pressed.connect(func() -> void: set_map_open(true))
    add_child(_button)

    _overlay = Control.new()
    _overlay.name = "ParishMapOverlay"
    _overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    _overlay.mouse_filter = Control.MOUSE_FILTER_STOP
    _overlay.visible = false
    add_child(_overlay)

    var scrim := ColorRect.new()
    scrim.color = Color(0.015, 0.024, 0.020, 0.985)
    scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    scrim.mouse_filter = Control.MOUSE_FILTER_STOP
    _overlay.add_child(scrim)

    _canvas = CanvasScript.new()
    _canvas.name = "ParishMapCanvas"
    _canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    _canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _overlay.add_child(_canvas)

    var close := Button.new()
    close.name = "CloseParishMap"
    close.text = "×"
    close.focus_mode = Control.FOCUS_NONE
    close.anchor_left = 1.0
    close.anchor_right = 1.0
    close.offset_left = -70.0
    close.offset_right = -20.0
    close.offset_top = 18.0
    close.offset_bottom = 62.0
    close.add_theme_font_size_override("font_size", 26)
    close.pressed.connect(func() -> void: set_map_open(false))
    _overlay.add_child(close)

func _refresh_data() -> void:
    if _canvas == null:
        return
    var runtime := _parish_runtime()
    if runtime != null and runtime.has_method("map_data"):
        _canvas.call("configure", runtime.call("map_data"))
        return
    _canvas.call("configure", {})

func _on_parish_changed(parish: String) -> void:
    if _canvas != null:
        _canvas.call("set_current_parish", parish)

func _on_parish_data_reloaded(_ready: bool) -> void:
    _refresh_data()

func _parish_runtime() -> Node:
    if not is_inside_tree():
        return null
    return get_node_or_null("/root/ParishRuntime")

func _set_gameplay_input_enabled(enabled: bool) -> void:
    var tree := get_tree()
    if tree == null:
        return
    var scene: Node = tree.current_scene
    if scene == null:
        return
    var touch: Variant = scene.get("touch")
    if touch == null:
        return
    if not enabled and touch.has_method("clear_input"):
        touch.call("clear_input")
    var restore := enabled
    var hud: Variant = scene.get("hud")
    if enabled and hud != null:
        restore = not bool(hud.get("menu_open"))
    touch.set("input_enabled", restore)
