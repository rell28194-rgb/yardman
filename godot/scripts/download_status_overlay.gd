extends Node
class_name YardmanDownloadStatusOverlay

const ACTIVE_STATES := ["manifest", "downloading", "verifying", "installing"]
const SOURCE_SPECS := [
    {"node": "RemoteFleet", "label": "VEHICLE PACK"},
    {"node": "EnvironmentContent", "label": "ENVIRONMENT HD"},
    {"node": "HydrologyContent", "label": "JAMAICA RUNNING WATER"},
    {"node": "SurfaceContent", "label": "SURFACE HD"},
]

var _layer: CanvasLayer
var _panel: PanelContainer
var _title: Label
var _stage: Label
var _detail: Label
var _progress: ProgressBar
var _active_source := ""
var _hide_at_msec: int = 0

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    _build_ui()
    call_deferred("_bind_sources")
    set_process(true)

func _process(_delta: float) -> void:
    if _panel == null or not _panel.visible or _hide_at_msec <= 0:
        return
    if Time.get_ticks_msec() >= _hide_at_msec:
        _panel.visible = false
        _hide_at_msec = 0

func _build_ui() -> void:
    _layer = CanvasLayer.new()
    _layer.layer = 120
    add_child(_layer)

    _panel = PanelContainer.new()
    _panel.name = "DownloadStatusPanel"
    _panel.anchor_left = 0.5
    _panel.anchor_right = 0.5
    _panel.offset_left = -340.0
    _panel.offset_right = 340.0
    _panel.offset_top = 18.0
    _panel.offset_bottom = 154.0
    _panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _panel.visible = false
    _layer.add_child(_panel)

    var column := VBoxContainer.new()
    column.mouse_filter = Control.MOUSE_FILTER_IGNORE
    column.add_theme_constant_override("separation", 6)
    _panel.add_child(column)

    _title = Label.new()
    _title.text = "DOWNLOADING GAME CONTENT"
    _title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _title.add_theme_font_size_override("font_size", 22)
    _title.mouse_filter = Control.MOUSE_FILTER_IGNORE
    column.add_child(_title)

    _stage = Label.new()
    _stage.text = "PREPARING"
    _stage.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _stage.add_theme_font_size_override("font_size", 16)
    _stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
    column.add_child(_stage)

    _progress = ProgressBar.new()
    _progress.min_value = 0.0
    _progress.max_value = 100.0
    _progress.value = 0.0
    _progress.show_percentage = true
    _progress.custom_minimum_size = Vector2(640.0, 30.0)
    _progress.mouse_filter = Control.MOUSE_FILTER_IGNORE
    column.add_child(_progress)

    _detail = Label.new()
    _detail.text = "Preparing download…"
    _detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
    column.add_child(_detail)

func _bind_sources() -> void:
    for spec in SOURCE_SPECS:
        var node_name := str(spec.get("node", ""))
        var label := str(spec.get("label", node_name))
        var source := get_node_or_null("/root/" + node_name)
        if source == null:
            continue
        var state_cb := Callable(self, "_on_source_state_changed").bind(label)
        var progress_cb := Callable(self, "_on_source_progress").bind(label)
        if source.has_signal("state_changed") and not source.is_connected("state_changed", state_cb):
            source.connect("state_changed", state_cb)
        if source.has_signal("progress_changed") and not source.is_connected("progress_changed", progress_cb):
            source.connect("progress_changed", progress_cb)
        if source.has_method("get_state") and source.has_method("get_message"):
            var state := str(source.call("get_state"))
            if state in ACTIVE_STATES:
                _on_source_state_changed(state, str(source.call("get_message")), label)

func _on_source_state_changed(state: String, message: String, source_label: String) -> void:
    if _panel == null:
        return
    if state in ACTIVE_STATES:
        _active_source = source_label
        _hide_at_msec = 0
        _panel.visible = true
        _title.text = "DOWNLOADING GAME CONTENT"
        match state:
            "manifest":
                _stage.text = source_label + " · CHECKING FILES"
                _progress.value = 0.0
            "downloading":
                _stage.text = source_label + " · DOWNLOADING"
            "verifying":
                _stage.text = source_label + " · VERIFYING"
                _progress.value = 100.0
            "installing":
                _stage.text = source_label + " · INSTALLING"
                _progress.value = 100.0
        _detail.text = message if not message.is_empty() else "Working… keep the game open."
        return
    if state == "installed" and (_active_source == source_label or _active_source.is_empty()):
        _active_source = source_label
        _panel.visible = true
        _title.text = "CONTENT READY"
        _stage.text = source_label + " · INSTALLED"
        _progress.value = 100.0
        _detail.text = message if not message.is_empty() else "Download verified and installed."
        _hide_at_msec = Time.get_ticks_msec() + 3500
        return
    if state == "error":
        _active_source = source_label
        _panel.visible = true
        _title.text = "CONTENT DOWNLOAD NEEDS ATTENTION"
        _stage.text = source_label + " · ERROR"
        _detail.text = message if not message.is_empty() else "Download failed. Open the content panel to retry."
        _hide_at_msec = Time.get_ticks_msec() + 10000

func _on_source_progress(downloaded_bytes: int, total_bytes: int, source_label: String) -> void:
    if _panel == null:
        return
    _active_source = source_label
    _hide_at_msec = 0
    _panel.visible = true
    _title.text = "DOWNLOADING GAME CONTENT"
    _stage.text = source_label + " · DOWNLOADING"
    var downloaded := maxi(downloaded_bytes, 0)
    var total := maxi(total_bytes, 0)
    if total > 0:
        var percent := clampf(float(downloaded) * 100.0 / float(total), 0.0, 100.0)
        _progress.value = percent
        _detail.text = "%s / %s · %.1f%% · keep the game open" % [_format_bytes(downloaded), _format_bytes(total), percent]
    else:
        _progress.value = 0.0
        _detail.text = "%s downloaded · total size pending" % _format_bytes(downloaded)

func _format_bytes(value: int) -> String:
    var bytes := maxi(value, 0)
    if bytes >= 1_000_000:
        return "%.1f MB" % (float(bytes) / 1_000_000.0)
    if bytes >= 1_000:
        return "%.1f KB" % (float(bytes) / 1_000.0)
    return "%d B" % bytes

func debug_snapshot() -> Dictionary:
    return {
        "visible": _panel != null and _panel.visible,
        "title": _title.text if _title != null else "",
        "stage": _stage.text if _stage != null else "",
        "detail": _detail.text if _detail != null else "",
        "progress": float(_progress.value) if _progress != null else -1.0,
        "layer": int(_layer.layer) if _layer != null else -1,
    }
