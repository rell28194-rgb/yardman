extends CanvasLayer

signal vehicle_selected(vehicle_id: String)

const Catalog = preload("res://scripts/vehicle_catalog.gd")
const SETTINGS_PATH := "user://yardman/vehicle.json"
const STARTER_VEHICLE_ID := "toyota_crown"

var _selected_id := STARTER_VEHICLE_ID
var _root: Control
var _garage_button: Button
var _panel: PanelContainer
var _modal: ColorRect
var _selector: OptionButton
var _info: Label
var _status: Label
var _apply_button: Button
var _initial_applied := false
var _paused_by_garage := false
var _applied_scene_id := 0
var _applied_controller_id := 0
var _last_selection_error := ""

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    layer = 90
    _load_selection()
    _build_ui()

func _process(_delta: float) -> void:
    var scene := get_tree().current_scene
    var controller: Object = _scene_controller(scene)
    var scene_id := scene.get_instance_id() if is_instance_valid(scene) else 0
    var controller_id := controller.get_instance_id() if is_instance_valid(controller) else 0
    if scene_id != _applied_scene_id or controller_id != _applied_controller_id:
        _initial_applied = false
    if not _initial_applied and apply_selected_to_scene(scene):
        vehicle_selected.emit(_selected_id)

func _exit_tree() -> void:
    if _paused_by_garage and get_tree() != null:
        get_tree().paused = false
        _paused_by_garage = false

func _input(event: InputEvent) -> void:
    if not is_open() or not event is InputEventKey:
        return
    var key: int = event.physical_keycode if event.physical_keycode != 0 else event.keycode
    if (key == KEY_ESCAPE or key == KEY_M) and event.pressed and not event.echo:
        close_garage()
        get_viewport().set_input_as_handled()

func available_vehicle_ids() -> Array:
    return Catalog.production_ids()

func selected_vehicle_id() -> String:
    return _selected_id

# Compatibility helpers intentionally expose every production vehicle as free.
# Yardman's map+cars reset has no job wallet, ownership grind, or purchase gate.
func owned_vehicle_ids() -> Array[String]:
    var result: Array[String] = []
    for vehicle_id in Catalog.production_ids():
        result.append(str(vehicle_id))
    return result

static func vehicle_price_jmd(_vehicle_id: String) -> int:
    return 0

static func normalized_owned_ids(_value: Variant, _selected_id: String) -> Array[String]:
    var result: Array[String] = []
    for vehicle_id in Catalog.production_ids():
        result.append(str(vehicle_id))
    return result

func is_vehicle_owned(vehicle_id: String) -> bool:
    return Catalog.production_ids().has(vehicle_id)

func wallet_jmd() -> int:
    return 0

func can_afford_vehicle(vehicle_id: String) -> bool:
    return Catalog.production_ids().has(vehicle_id)

func purchase_vehicle(vehicle_id: String, apply_to_game: bool = true) -> bool:
    return set_selected_vehicle(vehicle_id, true, apply_to_game)

func last_selection_error() -> String:
    return _last_selection_error

func is_open() -> bool:
    return is_instance_valid(_panel) and _panel.visible

func set_selected_vehicle(vehicle_id: String, persist: bool = true, apply_to_game: bool = true) -> bool:
    _last_selection_error = ""
    if not Catalog.production_ids().has(vehicle_id):
        _last_selection_error = "VEHICLE UNAVAILABLE"
        _refresh_action_state()
        return false
    var scene := get_tree().current_scene
    if apply_to_game:
        if not _switch_allowed(scene):
            _last_selection_error = "STOP THE VEHICLE BEFORE SWITCHING"
            _refresh_action_state()
            return false
        if not _apply_vehicle_to_scene(scene, vehicle_id):
            _last_selection_error = "VEHICLE ASSET NOT READY"
            _refresh_action_state()
            return false
    _selected_id = vehicle_id
    if persist and not _save_selection():
        _last_selection_error = "COULD NOT SAVE VEHICLE SELECTION"
    if apply_to_game:
        _remember_applied_scene(scene)
        vehicle_selected.emit(_selected_id)
    _sync_selector()
    _refresh_action_state()
    return _last_selection_error.is_empty()

func apply_selected_to_scene(scene: Node) -> bool:
    if not Catalog.production_ids().has(_selected_id):
        _selected_id = STARTER_VEHICLE_ID
    if not _switch_allowed(scene) or not _apply_vehicle_to_scene(scene, _selected_id):
        return false
    _remember_applied_scene(scene)
    return true

func _scene_controller(scene: Node) -> Object:
    if not is_instance_valid(scene):
        return null
    var controller = scene.get("vehicle")
    return controller if controller is Object and is_instance_valid(controller) else null

func _apply_vehicle_to_scene(scene: Node, vehicle_id: String) -> bool:
    var controller: Object = _scene_controller(scene)
    if controller == null or not controller.has_method("apply_profile"):
        return false
    controller.call("apply_profile", vehicle_id)
    var active_id = controller.get("vehicle_id")
    if active_id != null and str(active_id) != vehicle_id:
        return false
    var visual = controller.get("visual")
    if visual is Node:
        var requested := str(visual.get_meta("yardman_requested_hero_scene", ""))
        var missing := bool(visual.get_meta("yardman_hero_asset_missing_or_invalid", false))
        if missing and not requested.is_empty():
            return false
    return true

func _remember_applied_scene(scene: Node) -> void:
    if scene != get_tree().current_scene:
        return
    var controller: Object = _scene_controller(scene)
    _applied_scene_id = scene.get_instance_id() if is_instance_valid(scene) else 0
    _applied_controller_id = controller.get_instance_id() if controller != null else 0
    _initial_applied = true

func _switch_allowed(scene: Node = null) -> bool:
    if scene == null:
        scene = get_tree().current_scene
    var controller: Object = _scene_controller(scene)
    if controller == null:
        return true
    var speed_value = controller.get("speed_mps")
    if speed_value == null:
        return true
    if not (speed_value is int or speed_value is float):
        return false
    var speed := float(speed_value)
    return is_finite(speed) and absf(speed) <= 1.5

func open_garage() -> void:
    if _panel == null or is_open():
        return
    _populate_selector()
    _modal.visible = true
    _panel.visible = true
    _garage_button.disabled = true
    _sync_selector()
    _refresh_action_state()
    _selector.grab_focus()
    if not get_tree().paused:
        get_tree().paused = true
        _paused_by_garage = true

func close_garage() -> void:
    if _panel != null:
        _panel.visible = false
    if _modal != null:
        _modal.visible = false
    if _garage_button != null:
        _garage_button.disabled = false
    if _paused_by_garage:
        get_tree().paused = false
        _paused_by_garage = false

func _build_ui() -> void:
    _root = Control.new()
    _root.name = "GarageUI"
    _root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    _root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(_root)

    _garage_button = Button.new()
    _garage_button.name = "GarageButton"
    _garage_button.text = "VEHICLES"
    _garage_button.tooltip_text = "Select a verified Yardman vehicle"
    _garage_button.custom_minimum_size = Vector2(156.0, 56.0)
    _garage_button.set_anchor(SIDE_LEFT, 1.0)
    _garage_button.set_anchor(SIDE_RIGHT, 1.0)
    _garage_button.offset_left = -174.0
    _garage_button.offset_right = -18.0
    _garage_button.offset_top = 18.0
    _garage_button.offset_bottom = 74.0
    _garage_button.mouse_filter = Control.MOUSE_FILTER_STOP
    _garage_button.pressed.connect(open_garage)
    _root.add_child(_garage_button)

    _modal = ColorRect.new()
    _modal.name = "VehicleModal"
    _modal.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    _modal.color = Color(0.01, 0.016, 0.025, 0.84)
    _modal.mouse_filter = Control.MOUSE_FILTER_STOP
    _modal.visible = false
    _root.add_child(_modal)

    _panel = PanelContainer.new()
    _panel.name = "VehiclePanel"
    _panel.set_anchor(SIDE_LEFT, 0.5)
    _panel.set_anchor(SIDE_RIGHT, 0.5)
    _panel.set_anchor(SIDE_TOP, 0.5)
    _panel.set_anchor(SIDE_BOTTOM, 0.5)
    _panel.offset_left = -330.0
    _panel.offset_right = 330.0
    _panel.offset_top = -190.0
    _panel.offset_bottom = 190.0
    _panel.mouse_filter = Control.MOUSE_FILTER_STOP
    _panel.visible = false
    _root.add_child(_panel)

    var outer := VBoxContainer.new()
    outer.add_theme_constant_override("separation", 14)
    _panel.add_child(outer)

    var title := Label.new()
    title.text = "YARDMAN VEHICLES"
    title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    title.add_theme_font_size_override("font_size", 24)
    outer.add_child(title)

    var note := Label.new()
    note.text = "Crown + manifest-verified recovered fleet. No jobs. No purchase gate."
    note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    outer.add_child(note)

    _selector = OptionButton.new()
    _selector.name = "VehicleSelector"
    _selector.custom_minimum_size = Vector2(0.0, 54.0)
    _selector.item_selected.connect(func(_index: int) -> void: _refresh_action_state())
    outer.add_child(_selector)

    _info = Label.new()
    _info.name = "VehicleInfo"
    _info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    outer.add_child(_info)

    _status = Label.new()
    _status.name = "VehicleStatus"
    _status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    outer.add_child(_status)

    var buttons := HBoxContainer.new()
    buttons.alignment = BoxContainer.ALIGNMENT_CENTER
    buttons.add_theme_constant_override("separation", 12)
    outer.add_child(buttons)

    _apply_button = Button.new()
    _apply_button.text = "USE VEHICLE"
    _apply_button.custom_minimum_size = Vector2(190.0, 52.0)
    _apply_button.pressed.connect(_apply_current_selector)
    buttons.add_child(_apply_button)

    var close_button := Button.new()
    close_button.text = "CLOSE"
    close_button.custom_minimum_size = Vector2(150.0, 52.0)
    close_button.pressed.connect(close_garage)
    buttons.add_child(close_button)

    _populate_selector()
    _sync_selector()
    _refresh_action_state()

func _populate_selector() -> void:
    if _selector == null:
        return
    var previous := _selected_id
    _selector.clear()
    for vehicle_id in Catalog.production_ids():
        var profile: Dictionary = Catalog.profile(str(vehicle_id))
        var label := str(profile.get("display_name", vehicle_id))
        _selector.add_item(label)
        _selector.set_item_metadata(_selector.item_count - 1, str(vehicle_id))
    if _selector.item_count == 0:
        _status.text = "PRIVATE FLEET NOT MOUNTED"
    _selected_id = previous if Catalog.has(previous) else STARTER_VEHICLE_ID

func _selector_vehicle_id() -> String:
    if _selector == null or _selector.item_count == 0:
        return ""
    var index := _selector.selected
    return str(_selector.get_item_metadata(index)) if index >= 0 else ""

func _sync_selector() -> void:
    if _selector == null:
        return
    for index in range(_selector.item_count):
        if str(_selector.get_item_metadata(index)) == _selected_id:
            _selector.select(index)
            break

func _refresh_action_state() -> void:
    if _selector == null or _info == null or _status == null or _apply_button == null:
        return
    var candidate := _selector_vehicle_id()
    if candidate.is_empty():
        _info.text = "No manifest-verified vehicle media available."
        _status.text = "PRIVATE FLEET NOT MOUNTED"
        _apply_button.disabled = true
        return
    var profile: Dictionary = Catalog.profile(candidate)
    _info.text = "%s\n%s" % [str(profile.get("display_name", candidate)), str(profile.get("hero_scene", ""))]
    _status.text = _last_selection_error if not _last_selection_error.is_empty() else ("ACTIVE" if candidate == _selected_id else "READY")
    _apply_button.disabled = not _switch_allowed()

func _apply_current_selector() -> void:
    var candidate := _selector_vehicle_id()
    if candidate.is_empty():
        return
    if set_selected_vehicle(candidate, true, true):
        _status.text = "ACTIVE"
        close_garage()

func _load_selection() -> void:
    _selected_id = STARTER_VEHICLE_ID
    if not FileAccess.file_exists(SETTINGS_PATH):
        return
    var parsed = JSON.parse_string(FileAccess.get_file_as_string(SETTINGS_PATH))
    if parsed is Dictionary:
        var candidate := str(parsed.get("selected_vehicle", STARTER_VEHICLE_ID))
        if Catalog.has(candidate):
            _selected_id = candidate

func _save_selection() -> bool:
    var directory := SETTINGS_PATH.get_base_dir()
    if not DirAccess.dir_exists_absolute(directory):
        if DirAccess.make_dir_recursive_absolute(directory) != OK:
            return false
    var file := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
    if file == null:
        return false
    file.store_string(JSON.stringify({"selected_vehicle": _selected_id}))
    file.flush()
    return file.get_error() == OK
