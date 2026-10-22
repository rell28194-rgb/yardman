extends CanvasLayer
class_name YardmanVehicleSelectorRuntime

const Catalog = preload("res://scripts/vehicle_catalog.gd")
const References = preload("res://scripts/reference_assets.gd")
const AcceptedModel = preload("res://scripts/vehicle_model.gd")
const FleetModel = preload("res://scripts/fleet_vehicle_model.gd")
const SAVE_PATH := "user://yardman/vehicle-selection.json"
const GARAGE_LAYER := 110

var _game: Node
var _controller
var _body: CharacterBody3D
var _vehicle_ids: Array[String] = []
var _button: Button
var _panel: PanelContainer
var _options: OptionButton
var _status: Label
var _download_button: Button
var _download_progress: ProgressBar
var _remote: Node
var _current_id := Catalog.DEFAULT_ID
var _touch_input_before_panel := true

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    set_process(true)
    set_process_input(true)
    call_deferred("_try_attach_to_current_game")

func _process(_delta: float) -> void:
    if _game == null:
        _try_attach_to_current_game()

func _input(event: InputEvent) -> void:
    if _garage_key_pressed(event):
        _toggle_panel()
        get_viewport().set_input_as_handled()
        return
    if event is InputEventScreenTouch:
        var touch_event := event as InputEventScreenTouch
        if touch_event.pressed and _garage_button_hit(touch_event.position):
            _toggle_panel()
            get_viewport().set_input_as_handled()

func _garage_key_pressed(event: InputEvent) -> bool:
    if not event is InputEventKey:
        return false
    var key_event := event as InputEventKey
    if not key_event.pressed or key_event.echo:
        return false
    return key_event.keycode == KEY_G or key_event.physical_keycode == KEY_G

func _garage_button_hit(point: Vector2) -> bool:
    return _button != null and _button.visible and not _button.disabled and _button.get_global_rect().has_point(point)

func _toggle_panel() -> void:
    if _panel == null:
        return
    _set_panel_visible(not _panel.visible)

func _set_panel_visible(value: bool) -> void:
    if _panel == null:
        return
    if _panel.visible == value:
        return
    _panel.visible = value
    _set_gameplay_touch_enabled(not value)

func _set_gameplay_touch_enabled(enabled: bool) -> void:
    if _game == null:
        return
    var touch = _game.get("touch")
    if touch == null:
        return
    if enabled:
        touch.set("input_enabled", _touch_input_before_panel)
    else:
        _touch_input_before_panel = bool(touch.get("input_enabled"))
        touch.set("input_enabled", false)
        if touch.has_method("clear_input"):
            touch.call("clear_input")

func _try_attach_to_current_game() -> void:
    if _game != null or get_tree() == null:
        return
    var candidate := get_tree().current_scene
    if candidate == null:
        return
    var controller = candidate.get("vehicle")
    if controller == null:
        return
    var body = controller.get("body")
    if not body is CharacterBody3D:
        return
    set_process(false)
    attach(candidate)

func attach(game: Node) -> void:
    _game = game
    _controller = game.get("vehicle") if game != null else null
    _body = _controller.get("body") as CharacterBody3D if _controller != null else null
    layer = GARAGE_LAYER
    _build_ui()
    _bind_remote_fleet()
    _populate()
    if _controller == null or _body == null:
        _disable("Vehicle runtime unavailable.")
        return
    if _vehicle_ids.is_empty():
        _button.text = "GARAGE · GET CARS"
        _status.text = "Vehicle media is not installed. Download the fleet over Wi-Fi."
        return
    var saved := _load_saved_id()
    var initial := saved if _vehicle_ids.has(saved) else Catalog.DEFAULT_ID
    if not _vehicle_ids.has(initial):
        initial = _vehicle_ids[0]
    if initial == Catalog.DEFAULT_ID:
        _current_id = Catalog.DEFAULT_ID
        _select_id(_current_id)
        _update_labels()
    else:
        _apply_vehicle(initial, false)

func _build_ui() -> void:
    _button = Button.new()
    _button.text = "GARAGE"
    _button.set_anchors_preset(Control.PRESET_TOP_RIGHT)
    _button.position = Vector2(-228, 14)
    _button.size = Vector2(210, 58)
    _button.focus_mode = Control.FOCUS_NONE
    _button.mouse_filter = Control.MOUSE_FILTER_STOP
    _button.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
    _button.pressed.connect(_toggle_panel)
    add_child(_button)

    _panel = PanelContainer.new()
    _panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
    _panel.position = Vector2(-448, 78)
    _panel.size = Vector2(430, 330)
    _panel.mouse_filter = Control.MOUSE_FILTER_STOP
    _panel.visible = false
    add_child(_panel)

    var column := VBoxContainer.new()
    column.add_theme_constant_override("separation", 9)
    _panel.add_child(column)

    var title := Label.new()
    title.text = "OWNER GARAGE"
    title.add_theme_font_size_override("font_size", 20)
    column.add_child(title)

    var hint := Label.new()
    hint.text = "Tap GARAGE or press G"
    hint.add_theme_font_size_override("font_size", 13)
    column.add_child(hint)

    _options = OptionButton.new()
    _options.custom_minimum_size = Vector2(400, 48)
    _options.focus_mode = Control.FOCUS_NONE
    column.add_child(_options)

    var actions := HBoxContainer.new()
    actions.add_theme_constant_override("separation", 8)
    column.add_child(actions)

    var use_button := Button.new()
    use_button.text = "USE VEHICLE"
    use_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    use_button.custom_minimum_size.y = 48.0
    use_button.focus_mode = Control.FOCUS_NONE
    use_button.pressed.connect(_apply_selected)
    actions.add_child(use_button)

    var close := Button.new()
    close.text = "CLOSE"
    close.custom_minimum_size = Vector2(100.0, 48.0)
    close.focus_mode = Control.FOCUS_NONE
    close.pressed.connect(func() -> void: _set_panel_visible(false))
    actions.add_child(close)

    _download_button = Button.new()
    _download_button.text = "DOWNLOAD VEHICLES · WI-FI"
    _download_button.custom_minimum_size = Vector2(400, 48)
    _download_button.focus_mode = Control.FOCUS_NONE
    _download_button.pressed.connect(_start_or_resume_download)
    column.add_child(_download_button)

    _download_progress = ProgressBar.new()
    _download_progress.min_value = 0.0
    _download_progress.max_value = 100.0
    _download_progress.value = 0.0
    _download_progress.show_percentage = true
    _download_progress.custom_minimum_size = Vector2(400, 30)
    column.add_child(_download_progress)

    _status = Label.new()
    _status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _status.text = "Checking dedicated owner fleet..."
    column.add_child(_status)

func _bind_remote_fleet() -> void:
    _remote = get_node_or_null("/root/RemoteFleet")
    if _remote == null:
        _download_button.disabled = true
        _download_button.text = "VEHICLE DOWNLOAD UNAVAILABLE"
        return
    var state_cb := Callable(self, "_on_remote_state_changed")
    var progress_cb := Callable(self, "_on_remote_progress")
    var installed_cb := Callable(self, "_on_remote_installed")
    if _remote.has_signal("state_changed") and not _remote.is_connected("state_changed", state_cb):
        _remote.connect("state_changed", state_cb)
    if _remote.has_signal("progress_changed") and not _remote.is_connected("progress_changed", progress_cb):
        _remote.connect("progress_changed", progress_cb)
    if _remote.has_signal("installed") and not _remote.is_connected("installed", installed_cb):
        _remote.connect("installed", installed_cb)
    if _remote.has_method("get_state") and _remote.has_method("get_message"):
        _on_remote_state_changed(str(_remote.call("get_state")), str(_remote.call("get_message")))

func _start_or_resume_download() -> void:
    if _remote == null or not _remote.has_method("start_download"):
        _status.text = "Vehicle downloader is unavailable."
        return
    var state := str(_remote.call("get_state")) if _remote.has_method("get_state") else ""
    if state == "downloading" and _remote.has_method("cancel_download"):
        _remote.call("cancel_download")
        return
    _set_panel_visible(true)
    _remote.call("start_download")

func _on_remote_state_changed(state: String, message: String) -> void:
    if _download_button == null or _status == null:
        return
    match state:
        "installed":
            _download_button.text = "VEHICLES INSTALLED"
            _download_button.disabled = true
            _download_progress.value = 100.0
        "downloading":
            _download_button.text = "DOWNLOADING VEHICLES · TAP TO STOP"
            _download_button.disabled = false
            _set_panel_visible(true)
        "verifying":
            _download_button.text = "VERIFYING VEHICLES…"
            _download_button.disabled = true
            _set_panel_visible(true)
        "installing":
            _download_button.text = "INSTALLING VEHICLES…"
            _download_button.disabled = true
            _set_panel_visible(true)
        "error":
            _download_button.text = "RETRY VEHICLE DOWNLOAD"
            _download_button.disabled = false
            _set_panel_visible(true)
        _:
            _download_button.text = "DOWNLOAD VEHICLES · WI-FI"
            _download_button.disabled = false
    if not message.is_empty():
        _status.text = message

func _on_remote_progress(downloaded_bytes: int, total_bytes: int) -> void:
    if _download_progress == null or total_bytes <= 0:
        return
    var percent := clampf(float(downloaded_bytes) * 100.0 / float(total_bytes), 0.0, 100.0)
    _download_progress.value = percent
    if _status != null:
        _status.text = "DOWNLOADING VEHICLES · %.1f%% · %.1f / %.1f MB" % [
            percent,
            float(maxi(downloaded_bytes, 0)) / 1_000_000.0,
            float(total_bytes) / 1_000_000.0,
        ]

func _on_remote_installed() -> void:
    _populate()
    if _vehicle_ids.has(Catalog.DEFAULT_ID):
        _current_id = Catalog.DEFAULT_ID
        _select_id(_current_id)
        _update_labels()
    _status.text = "%d dedicated vehicles installed and ready." % _vehicle_ids.size()

func _disable(message: String) -> void:
    _button.disabled = true
    _button.text = "GARAGE · UNAVAILABLE"
    _status.text = message

func _manifest_has_exact_file(filename: String) -> bool:
    var manifest := References.manifest()
    if manifest.is_empty() or int(manifest.get("format_version", 0)) != 1:
        return false
    var count := 0
    for raw_record in manifest.get("files", []):
        if raw_record is Dictionary and str(raw_record.get("path", "")) == filename:
            count += 1
            var digest := str(raw_record.get("sha256", ""))
            if digest.length() != 64:
                return false
    return count == 1

func _dedicated_asset_available(vehicle_id: String) -> bool:
    if not Catalog.has(vehicle_id):
        return false
    var hero := Catalog.hero_scene(vehicle_id)
    if hero.is_empty() or not _manifest_has_exact_file(hero):
        return false
    return References.exact_asset_exists(hero)

func _populate() -> void:
    _vehicle_ids.clear()
    _options.clear()
    for vehicle_id in Catalog.production_ids():
        if not _dedicated_asset_available(vehicle_id):
            continue
        _vehicle_ids.append(vehicle_id)
        _options.add_item(Catalog.display_name(vehicle_id))
    if _vehicle_ids.has(Catalog.DEFAULT_ID):
        _select_id(Catalog.DEFAULT_ID)
    elif not _vehicle_ids.is_empty():
        _options.select(0)
    var remote_state := str(_remote.call("get_state")) if _remote != null and _remote.has_method("get_state") else ""
    if _vehicle_ids.size() >= 64:
        _download_button.text = "ALL 64 VEHICLES READY"
        _download_button.disabled = true
        _download_progress.value = 100.0
    if remote_state not in ["downloading", "verifying", "installing"]:
        _status.text = "Dedicated selectable vehicles: %d / 64" % _vehicle_ids.size()

func _apply_selected() -> void:
    if _options.selected < 0 or _options.selected >= _vehicle_ids.size():
        return
    _apply_vehicle(_vehicle_ids[_options.selected], true)

func _apply_vehicle(vehicle_id: String, persist: bool) -> bool:
    if _controller == null or _body == null or not _vehicle_ids.has(vehicle_id) or not _dedicated_asset_available(vehicle_id):
        return false
    if absf(float(_controller.get("speed_mps"))) > 0.5:
        _status.text = "Stop the car before changing vehicles."
        return false
    if vehicle_id == _current_id:
        _select_id(vehicle_id)
        _update_labels()
        return true

    var replacement: Node3D
    if vehicle_id == Catalog.DEFAULT_ID:
        replacement = AcceptedModel.new()
        replacement.call("build")
        if not bool(replacement.get("is_reference_model")):
            replacement.free()
            _status.text = "Crown dedicated asset failed validation."
            return false
    else:
        replacement = FleetModel.new()
        replacement.call("build", Catalog.hero_scene(vehicle_id))
        if bool(replacement.get_meta("yardman_hero_asset_missing_or_invalid", false)) or not bool(replacement.get_meta("yardman_dedicated_vehicle_mesh", false)):
            replacement.free()
            _status.text = "%s failed dedicated-asset validation." % Catalog.display_name(vehicle_id)
            return false

    _controller.call("reset_motion")
    var old_visual := _controller.get("visual") as Node3D
    if old_visual != null:
        if old_visual.get_parent() == _body:
            _body.remove_child(old_visual)
        old_visual.queue_free()
    replacement.name = "VisualRig"
    _body.add_child(replacement)
    _controller.set("visual", replacement)
    _controller.set("wheelbase_m", clampf(float(replacement.get("wheelbase_m")), 1.8, 4.5))
    _fit_collision(replacement)
    _current_id = vehicle_id
    _game.set_meta("yardman_selected_vehicle_id", vehicle_id)
    _select_id(vehicle_id)
    _update_labels()
    if persist:
        _save_id(vehicle_id)
    return true

func _fit_collision(visual: Node3D) -> void:
    if not bool(visual.get("is_reference_model")):
        return
    var bounds: AABB = visual.get("geometry_bounds")
    for node in _body.find_children("*", "CollisionShape3D", true, false):
        var collision := node as CollisionShape3D
        if collision == null or not collision.shape is BoxShape3D:
            continue
        var shape := collision.shape.duplicate() as BoxShape3D
        shape.size = Vector3(bounds.size.x * 0.97, maxf(bounds.size.y * 0.90, 1.0), bounds.size.z * 0.97)
        collision.shape = shape
        var centre := bounds.get_center()
        collision.position = Vector3(centre.x, maxf(shape.size.y * 0.5, 0.5), centre.z)
        break

func _update_labels() -> void:
    var name := Catalog.display_name(_current_id)
    _button.text = "GARAGE · " + name
    _status.text = "%s selected · %d dedicated vehicles available" % [name, _vehicle_ids.size()]

func _select_id(vehicle_id: String) -> void:
    var index := _vehicle_ids.find(vehicle_id)
    if index >= 0:
        _options.select(index)

func _load_saved_id() -> String:
    if not FileAccess.file_exists(SAVE_PATH):
        return Catalog.DEFAULT_ID
    var parsed = JSON.parse_string(FileAccess.get_file_as_string(SAVE_PATH))
    if not parsed is Dictionary:
        return Catalog.DEFAULT_ID
    return str(parsed.get("vehicle_id", Catalog.DEFAULT_ID))

func _save_id(vehicle_id: String) -> void:
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://yardman"))
    var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
    if file != null:
        file.store_string(JSON.stringify({"vehicle_id": vehicle_id}))
