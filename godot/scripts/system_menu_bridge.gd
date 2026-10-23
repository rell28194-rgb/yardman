extends Node
class_name YardmanSystemMenuBridge

const RUNTIME_PANELS := [
    "VehicleGarage",
    "EnvironmentContent",
    "HydrologyContent",
    "SurfaceContent",
]
const LEGACY_LAUNCHERS := {
    "VehicleGarage": ["GARAGE", "GARAGE · GET CARS"],
    "EnvironmentContent": ["CONTENT"],
    "HydrologyContent": ["RIVERS"],
    "SurfaceContent": ["SURFACES"],
}
const DOWNLOAD_ORDER := ["RemoteFleet", "EnvironmentContent", "HydrologyContent", "SurfaceContent"]
const DOWNLOAD_LABELS := {
    "RemoteFleet": "VEHICLES",
    "EnvironmentContent": "ENV",
    "HydrologyContent": "RIVERS",
    "SurfaceContent": "SURFACES",
}
const DOWNLOAD_ACTIVE_STATES := ["manifest", "downloading", "verifying", "installing"]
const WEATHER_MODES := ["Dynamic", "Clear", "Shower"]

var _hud: Control
var _rows: VBoxContainer
var _weather_menu: OptionButton
var _attached := false
var _clock := 0.0
var _suppressed_launchers := 0
var _download_sources: Dictionary = {}
var _download_records: Dictionary = {}
var _download_indicator: PanelContainer
var _download_label: Label
var _download_progress: ProgressBar

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    if get_tree() != null and not get_tree().node_added.is_connected(_on_node_added):
        get_tree().node_added.connect(_on_node_added)
    set_process(true)
    call_deferred("_try_attach")

func _exit_tree() -> void:
    var tree := get_tree()
    if tree != null and tree.node_added.is_connected(_on_node_added):
        tree.node_added.disconnect(_on_node_added)

func _process(delta: float) -> void:
    _clock += maxf(delta, 0.0)
    if _clock < 0.25:
        return
    _clock = 0.0
    _bind_download_sources()
    if not _attached or not is_instance_valid(_hud):
        _try_attach()
        return
    _hide_legacy_launchers()
    _sync_weather_menu()
    _refresh_download_indicator()

func _on_node_added(node: Node) -> void:
    # SystemMenuBridge autoloads before the optional-content and garage runtimes.
    # Suppress their legacy launchers synchronously as each Button enters the
    # SceneTree so CONTENT/RIVERS/SURFACES/GARAGE can never render for a frame.
    # The periodic sweep remains as a defensive repair path for replaced UI.
    if node is Button and suppress_legacy_launcher(node as Button):
        _suppressed_launchers += 1

static func launcher_owner_name(node: Node) -> String:
    var current := node.get_parent() if node != null else null
    while current != null:
        var name := str(current.name)
        if LEGACY_LAUNCHERS.has(name):
            return name
        current = current.get_parent()
    return ""

static func suppress_legacy_launcher(button: Button) -> bool:
    if button == null:
        return false
    var owner := launcher_owner_name(button)
    if owner.is_empty():
        return false
    var captions: Array = LEGACY_LAUNCHERS.get(owner, [])
    if button.text not in captions:
        return false
    button.visible = false
    button.mouse_filter = Control.MOUSE_FILTER_IGNORE
    button.focus_mode = Control.FOCUS_NONE
    return true

static func download_indicator_model(label: String, state: String, downloaded_bytes: int,
        total_bytes: int, additional_active: int = 0) -> Dictionary:
    if state not in DOWNLOAD_ACTIVE_STATES:
        return {"visible": false, "text": "", "percent": 0.0, "show_bar": false}
    var safe_downloaded := maxi(downloaded_bytes, 0)
    var safe_total := maxi(total_bytes, 0)
    var show_bar := state == "downloading" and safe_total > 0
    var percent := clampf(float(safe_downloaded) / float(safe_total) * 100.0, 0.0, 100.0) if show_bar else 0.0
    var text := "↓ %s" % label
    if show_bar:
        # Large vehicle packs can spend meaningful time below one percent. Keep
        # one decimal below 10% so resumed/in-flight progress is visible rather
        # than sitting at a misleading integer 0%.
        text += (" %.1f%%" % percent) if percent > 0.0 and percent < 10.0 else (" %d%%" % int(floor(percent + 0.5)))
    else:
        var stage: String = str({
            "manifest": "CHECK",
            "downloading": "START",
            "verifying": "VERIFY",
            "installing": "INSTALL",
        }.get(state, state.to_upper()))
        text += " · %s" % stage
    if additional_active > 0:
        text += " +%d" % additional_active
    return {"visible": true, "text": text, "percent": percent, "show_bar": show_bar}

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
    _build_download_indicator()
    if _rows.has_node("YardmanSystemsSection"):
        _attached = true
        _hide_legacy_launchers()
        _bind_download_sources()
        _refresh_download_indicator()
        return
    _build_section()
    _attached = true
    _hide_legacy_launchers()
    _bind_download_sources()
    _refresh_download_indicator()

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

func _build_download_indicator() -> void:
    if _hud == null or _download_indicator != null:
        return
    var existing := _hud.get_node_or_null("DownloadIndicator") as PanelContainer
    if existing != null:
        _download_indicator = existing
        _download_label = existing.get_node_or_null("Content/Label") as Label
        _download_progress = existing.get_node_or_null("Content/Progress") as ProgressBar
        return
    _download_indicator = PanelContainer.new()
    _download_indicator.name = "DownloadIndicator"
    _download_indicator.set_anchors_preset(Control.PRESET_TOP_RIGHT)
    _download_indicator.offset_left = -260.0
    _download_indicator.offset_top = 20.0
    _download_indicator.offset_right = -82.0
    _download_indicator.offset_bottom = 55.0
    _download_indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _download_indicator.visible = false
    var style := StyleBoxFlat.new()
    style.bg_color = Color(0.045, 0.062, 0.056, 0.82)
    style.border_color = Color(0.70, 0.74, 0.68, 0.28)
    style.set_border_width_all(1)
    style.set_corner_radius_all(6)
    style.content_margin_left = 8.0
    style.content_margin_right = 8.0
    style.content_margin_top = 4.0
    style.content_margin_bottom = 4.0
    _download_indicator.add_theme_stylebox_override("panel", style)
    _hud.add_child(_download_indicator)

    var content := VBoxContainer.new()
    content.name = "Content"
    content.mouse_filter = Control.MOUSE_FILTER_IGNORE
    content.add_theme_constant_override("separation", 2)
    _download_indicator.add_child(content)
    _download_label = Label.new()
    _download_label.name = "Label"
    _download_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _download_label.add_theme_font_size_override("font_size", 12)
    _download_label.add_theme_color_override("font_color", Color(0.95, 0.93, 0.85))
    content.add_child(_download_label)
    _download_progress = ProgressBar.new()
    _download_progress.name = "Progress"
    _download_progress.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _download_progress.min_value = 0.0
    _download_progress.max_value = 100.0
    _download_progress.value = 0.0
    _download_progress.show_percentage = false
    _download_progress.custom_minimum_size.y = 4.0
    content.add_child(_download_progress)

func _bind_download_sources() -> void:
    for source_name: String in DOWNLOAD_ORDER:
        var runtime := get_node_or_null("/root/" + source_name)
        if runtime == null:
            continue
        var instance_id := runtime.get_instance_id()
        if int(_download_sources.get(source_name, 0)) == instance_id:
            continue
        var state_callback := Callable(self, "_on_download_state").bind(source_name)
        var progress_callback := Callable(self, "_on_download_progress").bind(source_name)
        if runtime.has_signal("state_changed") and not runtime.is_connected("state_changed", state_callback):
            runtime.connect("state_changed", state_callback)
        if runtime.has_signal("progress_changed") and not runtime.is_connected("progress_changed", progress_callback):
            runtime.connect("progress_changed", progress_callback)
        _download_sources[source_name] = instance_id
        var state := str(runtime.call("get_state")) if runtime.has_method("get_state") else "idle"
        var record: Dictionary = _download_records.get(source_name, {})
        record["state"] = state
        record["downloaded"] = int(record.get("downloaded", 0))
        record["total"] = int(record.get("total", 0))
        _download_records[source_name] = record
    _refresh_download_indicator()

func _on_download_state(state: String, _message: String, source_name: String) -> void:
    var record: Dictionary = _download_records.get(source_name, {})
    record["state"] = state
    if state == "installed":
        record["downloaded"] = int(record.get("total", 0))
    _download_records[source_name] = record
    _refresh_download_indicator()

func _on_download_progress(downloaded_bytes: int, total_bytes: int, source_name: String) -> void:
    var record: Dictionary = _download_records.get(source_name, {})
    record["downloaded"] = maxi(downloaded_bytes, 0)
    record["total"] = maxi(total_bytes, 0)
    if not record.has("state"):
        var runtime := get_node_or_null("/root/" + source_name)
        record["state"] = str(runtime.call("get_state")) if runtime != null and runtime.has_method("get_state") else "downloading"
    _download_records[source_name] = record
    _refresh_download_indicator()

func _refresh_download_indicator() -> void:
    if _download_indicator == null or _download_label == null or _download_progress == null:
        return
    var active: Array[String] = []
    for source_name: String in DOWNLOAD_ORDER:
        var record: Dictionary = _download_records.get(source_name, {})
        if str(record.get("state", "idle")) in DOWNLOAD_ACTIVE_STATES:
            active.append(source_name)
    if active.is_empty():
        _download_indicator.visible = false
        _download_progress.visible = false
        return
    var primary := active[0]
    var record: Dictionary = _download_records.get(primary, {})
    var model := download_indicator_model(str(DOWNLOAD_LABELS.get(primary, primary)),
        str(record.get("state", "idle")), int(record.get("downloaded", 0)),
        int(record.get("total", 0)), active.size() - 1)
    _download_label.text = str(model.text)
    _download_progress.value = float(model.percent)
    _download_progress.visible = bool(model.show_bar)
    _download_indicator.visible = bool(model.visible)

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
        if button is Button:
            suppress_legacy_launcher(button)
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

func debug_state() -> Dictionary:
    return {
        "attached": _attached,
        "runtime_panels": RUNTIME_PANELS.size(),
        "legacy_launcher_families": LEGACY_LAUNCHERS.size(),
        "suppressed_launchers": _suppressed_launchers,
        "weather_modes": WEATHER_MODES.size(),
        "download_sources": DOWNLOAD_ORDER.size(),
        "download_indicator_visible": _download_indicator.visible if _download_indicator != null else false,
        "download_indicator_interactive": false,
    }
