extends Node
class_name YardmanSystemMenuBridge

const RUNTIME_PANELS := [
    "VehicleGarage",
    "EnvironmentContent",
    "HydrologyContent",
    "SurfaceContent",
]
const WEATHER_MODES := ["Dynamic", "Clear", "Shower"]

var _hud: Control
var _rows: VBoxContainer
var _weather_menu: OptionButton
var _attached := false
var _clock := 0.0

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    set_process(true)
    call_deferred("_try_attach")

func _process(delta: float) -> void:
    _clock += maxf(delta, 0.0)
    if not _attached or not is_instance_valid(_hud):
        if _clock >= 0.25:
            _clock = 0.0
            _try_attach()
        return
    if _clock >= 0.75:
        _clock = 0.0
        _hide_legacy_launchers()
        _sync_weather_menu()

func _try_attach() -> void:
    if get_tree() == null or get_tree().current_scene == null:
        return
    _hud = _find_hud(get_tree().current_scene)
    if _hud == null:
        return
    var scroll = _hud.get("_menu_scroll")
    if not scroll is ScrollContainer or scroll.get_child_count() == 0:
        return
    var candidate = scroll.get_child(0)
    if not candidate is VBoxContainer:
        return
    _rows = candidate
    if _rows.has_node("YardmanSystemsSection"):
        _attached = true
        _hide_legacy_launchers()
        return
    _build_section()
    _attached = true
    _hide_legacy_launchers()

func _find_hud(node: Node) -> Control:
    if node is Control:
        var script = node.get_script()
        if script != null and str(script.resource_path).ends_with("/hud.gd"):
            return node
    for child in node.get_children():
        var found := _find_hud(child)
        if found != null:
            return found
    return null

func _build_section() -> void:
    var section := VBoxContainer.new()
    section.name = "YardmanSystemsSection"
    section.add_theme_constant_override("separation", 8)
    _rows.add_child(HSeparator.new())
    _rows.add_child(section)

    var title := Label.new()
    title.text = "GARAGE & CONTENT"
    title.add_theme_font_size_override("font_size", 16)
    title.add_theme_color_override("font_color", Color(0.39, 0.72, 0.51))
    section.add_child(title)

    var detail := Label.new()
    detail.text = "Vehicles and optional world packs live here instead of covering the driving HUD."
    detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    detail.add_theme_font_size_override("font_size", 14)
    detail.add_theme_color_override("font_color", Color(0.70, 0.74, 0.68))
    section.add_child(detail)

    section.add_child(_menu_button("Garage & vehicles", func() -> void: _open_panel("VehicleGarage")))
    section.add_child(_menu_button("Environment HD", func() -> void: _open_panel("EnvironmentContent")))
    section.add_child(_menu_button("Rivers & streams", func() -> void: _open_panel("HydrologyContent")))
    section.add_child(_menu_button("Surface HD", func() -> void: _open_panel("SurfaceContent")))

    var weather_label := Label.new()
    weather_label.text = "Weather"
    weather_label.add_theme_font_size_override("font_size", 15)
    weather_label.add_theme_color_override("font_color", Color(0.70, 0.74, 0.68))
    section.add_child(weather_label)

    _weather_menu = OptionButton.new()
    _weather_menu.name = "WeatherMode"
    _weather_menu.custom_minimum_size.y = 44
    _weather_menu.focus_mode = Control.FOCUS_NONE
    for mode in WEATHER_MODES:
        _weather_menu.add_item(mode)
    _weather_menu.item_selected.connect(_on_weather_selected)
    section.add_child(_weather_menu)
    _sync_weather_menu()

func _menu_button(caption: String, action: Callable) -> Button:
    var button := Button.new()
    button.text = caption
    button.custom_minimum_size.y = 44
    button.focus_mode = Control.FOCUS_NONE
    button.pressed.connect(action)
    return button

func _open_panel(runtime_name: String) -> void:
    _close_runtime_panels()
    if _hud != null and _hud.has_method("set_menu_open"):
        _hud.call("set_menu_open", false)
    var runtime := get_node_or_null("/root/" + runtime_name)
    if runtime == null:
        return
    var panel = runtime.get("_panel")
    if not panel is PanelContainer:
        return
    panel.set_anchors_preset(Control.PRESET_CENTER)
    var panel_size := Vector2(430.0, 300.0)
    if runtime_name == "VehicleGarage":
        panel_size = Vector2(410.0, 320.0)
    panel.size = panel_size
    panel.position = -panel_size * 0.5
    panel.visible = true

func _close_runtime_panels() -> void:
    for runtime_name in RUNTIME_PANELS:
        var runtime := get_node_or_null("/root/" + runtime_name)
        if runtime == null:
            continue
        var panel = runtime.get("_panel")
        if panel is Control:
            panel.visible = false

func _hide_legacy_launchers() -> void:
    for runtime_name in RUNTIME_PANELS:
        var runtime := get_node_or_null("/root/" + runtime_name)
        if runtime == null:
            continue
        var button = runtime.get("_button")
        if button is Control:
            button.visible = false
    var weather := get_node_or_null("/root/WeatherFX")
    if weather != null:
        var weather_button = weather.get("_button")
        if weather_button is Control:
            weather_button.visible = false

func _on_weather_selected(index: int) -> void:
    if index < 0 or index >= WEATHER_MODES.size():
        return
    var weather := get_node_or_null("/root/WeatherFX")
    if weather != null and weather.has_method("set_mode"):
        weather.call("set_mode", WEATHER_MODES[index])

func _sync_weather_menu() -> void:
    if _weather_menu == null:
        return
    var weather := get_node_or_null("/root/WeatherFX")
    if weather == null or not weather.has_method("get_mode"):
        _weather_menu.disabled = true
        return
    _weather_menu.disabled = false
    var mode := str(weather.call("get_mode"))
    var index := WEATHER_MODES.find(mode)
    if index >= 0 and _weather_menu.selected != index:
        _weather_menu.select(index)
