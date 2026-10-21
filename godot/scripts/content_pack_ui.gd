extends CanvasLayer
class_name YardmanContentPackUI

const CREAM := Color(0.95, 0.93, 0.85)
const MUTED := Color(0.70, 0.74, 0.68)
const GREEN := Color(0.39, 0.72, 0.51)
const GOLD := Color(0.91, 0.71, 0.36)
const CHARCOAL := Color(0.045, 0.062, 0.056)

var _manager: Node
var _hud: Node
var _panel: PanelContainer
var _rows: Dictionary = {}
var _active_pack: String = ""

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    layer = 90
    _manager = get_node_or_null("/root/ContentPacks")
    _build_ui()
    _panel.visible = false
    call_deferred("_try_bind_hud")
    if _manager != null:
        _bind_manager()
        _rebuild_pack_rows()

func _try_bind_hud() -> void:
    if _hud != null or get_tree() == null:
        return
    var game: Node = get_tree().current_scene
    if game == null:
        call_deferred("_try_bind_hud")
        return
    var candidate: Variant = game.get("hud")
    if not candidate is Node:
        call_deferred("_try_bind_hud")
        return
    _hud = candidate as Node
    var callback := Callable(self, "_on_menu_toggled")
    if _hud.has_signal("menu_toggled") and not _hud.is_connected("menu_toggled", callback):
        _hud.connect("menu_toggled", callback)
    _on_menu_toggled(bool(_hud.get("menu_open")))

func _bind_manager() -> void:
    var state_callback := Callable(self, "_on_pack_state_changed")
    var progress_callback := Callable(self, "_on_pack_progress")
    var installed_callback := Callable(self, "_on_pack_installed")
    if _manager.has_signal("pack_state_changed") and not _manager.is_connected("pack_state_changed", state_callback):
        _manager.connect("pack_state_changed", state_callback)
    if _manager.has_signal("pack_progress") and not _manager.is_connected("pack_progress", progress_callback):
        _manager.connect("pack_progress", progress_callback)
    if _manager.has_signal("pack_installed") and not _manager.is_connected("pack_installed", installed_callback):
        _manager.connect("pack_installed", installed_callback)

func _build_ui() -> void:
    _panel = PanelContainer.new()
    _panel.name = "DownloadedContentPanel"
    _panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
    _panel.position = Vector2(20, -470)
    _panel.size = Vector2(430, 450)
    _panel.add_theme_stylebox_override("panel", _style(Color(CHARCOAL, 0.97), Color(0.20, 0.29, 0.23), 16, 20))
    add_child(_panel)

    var column := VBoxContainer.new()
    column.add_theme_constant_override("separation", 10)
    _panel.add_child(column)

    var title := Label.new()
    title.text = "DOWNLOADED CONTENT"
    title.add_theme_font_size_override("font_size", 20)
    title.add_theme_color_override("font_color", CREAM)
    column.add_child(title)

    var note := Label.new()
    note.text = "Optional world detail installs after the APK. Wi-Fi recommended. Packs are hash-verified before use."
    note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    note.add_theme_font_size_override("font_size", 14)
    note.add_theme_color_override("font_color", MUTED)
    column.add_child(note)

    var scroll := ScrollContainer.new()
    scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
    scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    column.add_child(scroll)

    var rows := VBoxContainer.new()
    rows.name = "PackRows"
    rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    rows.add_theme_constant_override("separation", 12)
    scroll.add_child(rows)

func _rebuild_pack_rows() -> void:
    if _manager == null or _panel == null:
        return
    var rows := _panel.find_child("PackRows", true, false) as VBoxContainer
    if rows == null:
        return
    for child: Node in rows.get_children():
        child.queue_free()
    _rows.clear()

    var ids: PackedStringArray = _manager.call("pack_ids")
    for pack_id: String in ids:
        var record: Dictionary = _manager.call("pack_record", pack_id)
        var status: Dictionary = _manager.call("pack_status", pack_id)
        var card := VBoxContainer.new()
        card.add_theme_constant_override("separation", 5)
        rows.add_child(card)

        var heading_row := HBoxContainer.new()
        card.add_child(heading_row)
        var label := Label.new()
        label.text = str(record.get("label", pack_id)).to_upper()
        label.add_theme_font_size_override("font_size", 16)
        label.add_theme_color_override("font_color", GREEN)
        label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        heading_row.add_child(label)

        var size_label := Label.new()
        size_label.add_theme_font_size_override("font_size", 14)
        size_label.add_theme_color_override("font_color", MUTED)
        var bytes: int = int(status.get("bytes", 0))
        size_label.text = _format_bytes(bytes) if bytes > 0 else "Not published"
        heading_row.add_child(size_label)

        var description := Label.new()
        description.text = str(record.get("description", ""))
        description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        description.add_theme_font_size_override("font_size", 13)
        description.add_theme_color_override("font_color", MUTED)
        card.add_child(description)

        var action_row := HBoxContainer.new()
        action_row.add_theme_constant_override("separation", 8)
        card.add_child(action_row)
        var status_label := Label.new()
        status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        status_label.add_theme_font_size_override("font_size", 14)
        status_label.add_theme_color_override("font_color", CREAM)
        action_row.add_child(status_label)

        var button := Button.new()
        button.custom_minimum_size = Vector2(118, 40)
        button.focus_mode = Control.FOCUS_NONE
        button.pressed.connect(func() -> void: _on_pack_button(pack_id))
        action_row.add_child(button)

        var progress := ProgressBar.new()
        progress.min_value = 0.0
        progress.max_value = 100.0
        progress.value = 0.0
        progress.show_percentage = true
        progress.custom_minimum_size.y = 20
        progress.visible = false
        card.add_child(progress)

        rows.add_child(HSeparator.new())
        _rows[pack_id] = {"button": button, "status": status_label, "progress": progress, "size": size_label}
        _refresh_row(pack_id)

func _refresh_row(pack_id: String) -> void:
    if _manager == null or not _rows.has(pack_id):
        return
    var row: Dictionary = _rows[pack_id]
    var button: Button = row.button
    var status_label: Label = row.status
    var progress: ProgressBar = row.progress
    var status: Dictionary = _manager.call("pack_status", pack_id)
    var installed: bool = bool(status.get("installed", false))
    var available: bool = bool(status.get("available", false))
    if installed:
        status_label.text = "Installed · v%d" % int(status.get("version", 0))
        status_label.add_theme_color_override("font_color", GREEN)
        button.text = "INSTALLED"
        button.disabled = true
        progress.visible = false
    elif not available:
        status_label.text = "Planned expansion"
        status_label.add_theme_color_override("font_color", MUTED)
        button.text = "COMING"
        button.disabled = true
        progress.visible = false
    elif _active_pack == pack_id:
        status_label.text = "Downloading / installing"
        status_label.add_theme_color_override("font_color", GOLD)
        button.text = "PAUSE"
        button.disabled = false
        progress.visible = true
    else:
        status_label.text = "Ready to install"
        status_label.add_theme_color_override("font_color", CREAM)
        button.text = "DOWNLOAD"
        button.disabled = not _active_pack.is_empty()
        progress.visible = false

func _refresh_all_rows() -> void:
    for raw_id: Variant in _rows.keys():
        _refresh_row(str(raw_id))

func _on_pack_button(pack_id: String) -> void:
    if _manager == null:
        return
    if _active_pack == pack_id:
        _manager.call("cancel_active_download")
        _active_pack = ""
        _refresh_all_rows()
        return
    if not _active_pack.is_empty():
        return
    if bool(_manager.call("start_pack", pack_id)):
        _active_pack = pack_id
        var row: Dictionary = _rows.get(pack_id, {}) as Dictionary
        if not row.is_empty():
            (row.progress as ProgressBar).value = 0.0
        _refresh_all_rows()

func _on_pack_state_changed(pack_id: String, state: String, message: String) -> void:
    if not _rows.has(pack_id):
        return
    var row: Dictionary = _rows[pack_id]
    var status_label: Label = row.status
    if state in ["error", "paused", "busy", "unavailable"]:
        if _active_pack == pack_id:
            _active_pack = ""
        status_label.text = message
        status_label.add_theme_color_override("font_color", GOLD if state != "error" else Color(0.95, 0.46, 0.40))
        (row.progress as ProgressBar).visible = false
        _refresh_all_rows()
    elif state in ["downloading", "verifying", "installing"]:
        _active_pack = pack_id
        status_label.text = message
        status_label.add_theme_color_override("font_color", GOLD)
        (row.progress as ProgressBar).visible = true
        _refresh_all_rows()
    elif state == "installed":
        _active_pack = ""
        _refresh_all_rows()

func _on_pack_progress(pack_id: String, downloaded_bytes: int, total_bytes: int) -> void:
    if not _rows.has(pack_id) or total_bytes <= 0:
        return
    var row: Dictionary = _rows[pack_id]
    var progress: ProgressBar = row.progress
    progress.visible = true
    progress.value = clampf(float(downloaded_bytes) * 100.0 / float(total_bytes), 0.0, 100.0)
    var status_label: Label = row.status
    status_label.text = "%s / %s" % [_format_bytes(downloaded_bytes), _format_bytes(total_bytes)]

func _on_pack_installed(pack_id: String, _version: int) -> void:
    if _active_pack == pack_id:
        _active_pack = ""
    _refresh_all_rows()

func _on_menu_toggled(open: bool) -> void:
    if _panel == null:
        return
    _panel.visible = open
    if open:
        _refresh_all_rows()
        _relayout()

func _relayout() -> void:
    if _panel == null:
        return
    var viewport_size: Vector2 = get_viewport().get_visible_rect().size
    var width: float = minf(430.0, viewport_size.x - 40.0)
    var height: float = minf(450.0, viewport_size.y - 110.0)
    _panel.size = Vector2(width, height)
    _panel.position = Vector2(20.0, viewport_size.y - height - 20.0)

func _format_bytes(value: int) -> String:
    var bytes: int = maxi(value, 0)
    if bytes >= 1073741824:
        return "%.1f GB" % (float(bytes) / 1073741824.0)
    if bytes >= 1048576:
        return "%.1f MB" % (float(bytes) / 1048576.0)
    if bytes >= 1024:
        return "%.0f KB" % (float(bytes) / 1024.0)
    return "%d B" % bytes

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
