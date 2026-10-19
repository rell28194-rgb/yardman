extends CanvasLayer

signal vehicle_selected(vehicle_id: String)

const Catalog = preload("res://scripts/vehicle_catalog.gd")
const References = preload("res://scripts/reference_assets.gd")
const SETTINGS_PATH := "user://yardman/vehicle.json"
const STARTER_VEHICLE_ID := "toyota_crown"
const SCRAPPED_IDS := {
    "toyota_mark_x": true,
    "toyota_mark_x_2013": true,
    "mark_x": true,
    "port_royal_992": true,
    "porsche_911_992": true,
    "992": true,
}

var _selected_id := STARTER_VEHICLE_ID
var _root: Control
var _garage_button: Button
var _panel: PanelContainer
var _modal: ColorRect
var _selector: OptionButton
var _status: Label
var _initial_applied := false
var _applied_scene_id := 0
var _applied_controller_id := 0
var _paused_by_garage := false
var _last_selection_error := ""

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    layer = 90
    _load_selection()
    _build_ui()

func _process(_delta: float) -> void:
    var scene := get_tree().current_scene
    var controller := _scene_controller(scene)
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

func available_vehicle_ids() -> Array:
    var result: Array = []
    for raw_id in Catalog.production_ids():
        var vehicle_id := str(raw_id)
        if _is_scrapped(vehicle_id):
            continue
        if not Catalog.has(vehicle_id):
            continue
        if not _source_ready(vehicle_id):
            continue
        if not result.has(vehicle_id):
            result.append(vehicle_id)
    return result

func selected_vehicle_id() -> String:
    return _selected_id

func selected_vehicle_ready() -> bool:
    return not _is_scrapped(_selected_id) and _source_ready(_selected_id)

func owned_vehicle_ids() -> Array[String]:
    var result: Array[String] = []
    for vehicle_id in available_vehicle_ids():
        result.append(str(vehicle_id))
    return result

static func vehicle_price_jmd(_vehicle_id: String) -> int:
    return 0

func wallet_jmd() -> int:
    return 0

func can_afford_vehicle(vehicle_id: String) -> bool:
    return available_vehicle_ids().has(vehicle_id)

func is_vehicle_owned(vehicle_id: String) -> bool:
    return available_vehicle_ids().has(vehicle_id)

func purchase_vehicle(vehicle_id: String, apply_to_game: bool = true) -> bool:
    return set_selected_vehicle(vehicle_id, true, apply_to_game)

func last_selection_error() -> String:
    return _last_selection_error

func is_open() -> bool:
    return is_instance_valid(_panel) and _panel.visible

func set_selected_vehicle(vehicle_id: String, persist: bool = true, apply_to_game: bool = true) -> bool:
    _last_selection_error = ""
    if _is_scrapped(vehicle_id):
        _last_selection_error = "VEHICLE SCRAPPED"
        return false
    if not available_vehicle_ids().has(vehicle_id):
        _last_selection_error = "SOURCE VEHICLE UNAVAILABLE"
        return false
    var scene := get_tree().current_scene
    if apply_to_game and not _switch_allowed(scene):
        _last_selection_error = "STOP THE VEHICLE BEFORE SWITCHING"
        return false
    if apply_to_game and not _apply_vehicle_to_scene(scene, vehicle_id):
        _last_selection_error = "VEHICLE SWITCH FAILED"
        return false
    _selected_id = vehicle_id
    if persist:
        _save_selection()
    _remember_applied_scene(scene)
    _sync_selector()
    if apply_to_game:
        vehicle_selected.emit(_selected_id)
    return true

func next_vehicle() -> bool:
    var ids := available_vehicle_ids()
    if ids.is_empty():
        _last_selection_error = "NO VERIFIED VEHICLES"
        return false
    var index := ids.find(_selected_id)
    return set_selected_vehicle(str(ids[(index + 1) % ids.size()]) if index >= 0 else str(ids[0]))

func previous_vehicle() -> bool:
    var ids := available_vehicle_ids()
    if ids.is_empty():
        _last_selection_error = "NO VERIFIED VEHICLES"
        return false
    var index := ids.find(_selected_id)
    return set_selected_vehicle(str(ids[(index - 1 + ids.size()) % ids.size()]) if index >= 0 else str(ids[0]))

func apply_selected_to_scene(scene: Node) -> bool:
    if not selected_vehicle_ready():
        _last_selection_error = "PRIVATE VEHICLE SOURCE PACK REQUIRED"
        return false
    if not _switch_allowed(scene):
        return false
    if not _apply_vehicle_to_scene(scene, _selected_id):
        return false
    _remember_applied_scene(scene)
    return true

func open_garage() -> void:
    if _panel == null or is_open():
        return
    _sync_selector()
    _status.text = "VERIFIED VEHICLES ONLY"
    _modal.visible = true
    _panel.visible = true
    _garage_button.disabled = true
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

func _is_scrapped(vehicle_id: String) -> bool:
    var normalized := vehicle_id.strip_edges().to_lower()
    return SCRAPPED_IDS.has(normalized)

func _source_ready(vehicle_id: String) -> bool:
    if _is_scrapped(vehicle_id) or not Catalog.has(vehicle_id):
        return false
    var profile: Dictionary = Catalog.profile(vehicle_id)
    var hero_scene := str(profile.get("hero_scene", ""))
    if hero_scene.is_empty():
        return false
    var path := References.ROOT + hero_scene
    if not ResourceLoader.exists(path):
        return false
    var manifest := References.manifest()
    return not manifest.is_empty() and References.manifest_file_matches(hero_scene, manifest)

func _scene_controller(scene: Node) -> Object:
    if not is_instance_valid(scene):
        return null
    var controller = scene.get("vehicle")
    return controller if controller is Object and is_instance_valid(controller) else null

func _apply_vehicle_to_scene(scene: Node, vehicle_id: String) -> bool:
    if not _source_ready(vehicle_id):
        return false
    var controller := _scene_controller(scene)
    if controller == null or not controller.has_method("apply_profile"):
        return false
    controller.call("apply_profile", vehicle_id)
    var active_id = controller.get("vehicle_id")
    return active_id != null and str(active_id) == vehicle_id

func _switch_allowed(scene: Node = null) -> bool:
    if scene == null:
        scene = get_tree().current_scene
    var controller := _scene_controller(scene)
    if controller == null:
        return true
    var speed_value = controller.get("speed_mps")
    if not (speed_value is int or speed_value is float):
        return true
    var speed := float(speed_value)
    return is_finite(speed) and absf(speed) <= 1.5

func _remember_applied_scene(scene: Node) -> void:
    if scene != get_tree().current_scene or not is_instance_valid(scene):
        return
    var controller := _scene_controller(scene)
    _applied_scene_id = scene.get_instance_id()
    _applied_controller_id = controller.get_instance_id() if controller != null else 0
    _initial_applied = controller != null

func _load_selection() -> void:
    var saved := STARTER_VEHICLE_ID
    if FileAccess.file_exists(SETTINGS_PATH):
        var payload = JSON.parse_string(FileAccess.get_file_as_string(SETTINGS_PATH))
        if payload is Dictionary:
            saved = str(payload.get("selected_vehicle", STARTER_VEHICLE_ID))
    if not _is_scrapped(saved) and _source_ready(saved):
        _selected_id = saved
        return
    if _source_ready(STARTER_VEHICLE_ID):
        _selected_id = STARTER_VEHICLE_ID
        return
    var ids := available_vehicle_ids()
    _selected_id = str(ids[0]) if not ids.is_empty() else STARTER_VEHICLE_ID

func _save_selection() -> void:
    DirAccess.make_dir_recursive_absolute("user://yardman")
    var handle := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
    if handle != null:
        handle.store_string(JSON.stringify({"format_version": 2, "selected_vehicle": _selected_id}))

func _build_ui() -> void:
    _root = Control.new()
    _root.name = "GarageUI"
    _root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    _root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(_root)

    _garage_button = Button.new()
    _garage_button.text = "CARS"
    _garage_button.tooltip_text = "Select verified vehicle"
    _garage_button.position = Vector2(18.0, 18.0)
    _garage_button.size = Vector2(128.0, 48.0)
    _garage_button.mouse_filter = Control.MOUSE_FILTER_STOP
    _garage_button.pressed.connect(open_garage)
    _root.add_child(_garage_button)

    _modal = ColorRect.new()
    _modal.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    _modal.color = Color(0.01, 0.016, 0.025, 0.84)
    _modal.mouse_filter = Control.MOUSE_FILTER_STOP
    _modal.visible = false
    _root.add_child(_modal)

    _panel = PanelContainer.new()
    _panel.position = Vector2(40.0, 90.0)
    _panel.size = Vector2(520.0, 260.0)
    _panel.visible = false
    _root.add_child(_panel)

    var column := VBoxContainer.new()
    column.add_theme_constant_override("separation", 12)
    _panel.add_child(column)

    var title := Label.new()
    title.text = "YARDMAN CARS"
    title.add_theme_font_size_override("font_size", 24)
    column.add_child(title)

    _selector = OptionButton.new()
    _selector.custom_minimum_size.y = 48.0
    _selector.item_selected.connect(_on_vehicle_chosen)
    column.add_child(_selector)

    _status = Label.new()
    _status.text = "VERIFIED VEHICLES ONLY"
    column.add_child(_status)

    var close := Button.new()
    close.text = "CLOSE"
    close.pressed.connect(close_garage)
    column.add_child(close)
    _sync_selector()

func _sync_selector() -> void:
    if _selector == null:
        return
    _selector.clear()
    var ids := available_vehicle_ids()
    for vehicle_id in ids:
        var profile: Dictionary = Catalog.profile(str(vehicle_id))
        _selector.add_item(str(profile.get("display_name", vehicle_id)))
        _selector.set_item_metadata(_selector.item_count - 1, str(vehicle_id))
    var selected_index := ids.find(_selected_id)
    if selected_index >= 0:
        _selector.select(selected_index)
    if _status != null and ids.is_empty():
        _status.text = "PRIVATE VEHICLE SOURCE PACK REQUIRED"

func _on_vehicle_chosen(index: int) -> void:
    if _selector == null or index < 0 or index >= _selector.item_count:
        return
    var vehicle_id := str(_selector.get_item_metadata(index))
    if set_selected_vehicle(vehicle_id):
        _status.text = "SELECTED: " + str(Catalog.profile(vehicle_id).get("display_name", vehicle_id))
    else:
        _status.text = _last_selection_error
