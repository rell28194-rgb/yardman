extends CanvasLayer

# Map + cars only. This selector deliberately has no economy, jobs, traffic,
# pedestrian, or purchase dependencies. A vehicle is selectable only when its
# exact named hero scene exists in the manifest-verified private pack.
const Catalog = preload("res://scripts/vehicle_catalog.gd")
const References = preload("res://scripts/reference_assets.gd")
const SETTINGS_PATH := "user://yardman/vehicle_selection.json"
const CROWN_ID := "toyota_crown"

var _root: Control
var _button: Button
var _panel: PanelContainer
var _selector: OptionButton
var _status: Label
var _eligible: Array[String] = []
var _selected_id := CROWN_ID
var _applied_scene_id := 0

func _ready() -> void:
    layer = 80
    process_mode = Node.PROCESS_MODE_ALWAYS
    _load_selection()
    _build_ui()
    set_process(true)

func _process(_delta: float) -> void:
    var scene := get_tree().current_scene
    if not is_instance_valid(scene):
        return
    var scene_id := scene.get_instance_id()
    if scene_id == _applied_scene_id:
        return
    if _apply_selected(scene):
        _applied_scene_id = scene_id
    else:
        _block_fake_visual(scene)

func available_vehicle_ids() -> Array[String]:
    _refresh_eligible()
    return _eligible.duplicate()

func selected_vehicle_id() -> String:
    return _selected_id

func _refresh_eligible() -> void:
    _eligible.clear()
    for raw_id in Catalog.production_ids():
        var vehicle_id := str(raw_id)
        if not Catalog.has(vehicle_id):
            continue
        var profile: Dictionary = Catalog.profile(vehicle_id)
        if _hero_ready(vehicle_id, profile):
            _eligible.append(vehicle_id)
    if _selector != null:
        _selector.clear()
        for vehicle_id in _eligible:
            var profile: Dictionary = Catalog.profile(vehicle_id)
            _selector.add_item(str(profile.get("display_name", vehicle_id)))
            _selector.set_item_metadata(_selector.item_count - 1, vehicle_id)
        _sync_selector()

func _hero_ready(vehicle_id: String, profile: Dictionary) -> bool:
    var hero_scene := str(profile.get("hero_scene", ""))
    if hero_scene.is_empty():
        return false
    # Crown is content-addressed by the canonical private-pack manifest. The
    # recovered fleet additionally carries its source hero hash in the registry.
    if vehicle_id != CROWN_ID:
        var hero_sha := str(profile.get("hero_sha256", ""))
        if hero_sha.length() != 64:
            return false
    return References.scene(hero_scene) != null

func _scene_controller(scene: Node) -> Object:
    if not is_instance_valid(scene):
        return null
    var controller = scene.get("vehicle")
    return controller if controller is Object and is_instance_valid(controller) else null

func _vehicle_stopped(controller: Object) -> bool:
    if not is_instance_valid(controller):
        return false
    var value = controller.get("speed_mps")
    return (value is int or value is float) and is_finite(float(value)) and absf(float(value)) < 0.35

func _apply_selected(scene: Node) -> bool:
    _refresh_eligible()
    if _eligible.is_empty():
        _set_status("PRIVATE VEHICLE MEDIA MISSING")
        return false
    if not _eligible.has(_selected_id):
        _selected_id = CROWN_ID if _eligible.has(CROWN_ID) else _eligible[0]
    var controller := _scene_controller(scene)
    if controller == null or not controller.has_method("apply_profile"):
        _set_status("VEHICLE CONTROLLER NOT READY")
        return false
    controller.call("apply_profile", _selected_id)
    var profile: Dictionary = Catalog.profile(_selected_id)
    var visual = controller.get("visual")
    if not is_instance_valid(visual):
        _set_status("VEHICLE VISUAL NOT READY")
        return false
    var expected_scene := str(profile.get("hero_scene", ""))
    var actual_scene := str(visual.get("reference_asset_name"))
    var missing := bool(visual.get_meta("yardman_hero_asset_missing_or_invalid", false))
    var procedural := bool(visual.get_meta("yardman_procedural_vehicle_fallback", false))
    if missing or procedural or expected_scene.is_empty() or actual_scene != expected_scene:
        visual.visible = false
        _set_status("BLOCKED: EXACT VEHICLE ART MISSING")
        return false
    visual.visible = true
    _save_selection()
    _set_status(str(profile.get("display_name", _selected_id)))
    _sync_selector()
    return true

func _block_fake_visual(scene: Node) -> void:
    var controller := _scene_controller(scene)
    if controller == null:
        return
    var visual = controller.get("visual")
    if not is_instance_valid(visual):
        return
    if bool(visual.get_meta("yardman_hero_asset_missing_or_invalid", false)) or bool(visual.get_meta("yardman_procedural_vehicle_fallback", false)):
        visual.visible = false

func _select_current() -> void:
    if _selector == null or _selector.selected < 0:
        return
    var candidate := str(_selector.get_item_metadata(_selector.selected))
    if not _eligible.has(candidate):
        _set_status("VEHICLE MEDIA UNAVAILABLE")
        return
    var scene := get_tree().current_scene
    var controller := _scene_controller(scene)
    if controller == null or not _vehicle_stopped(controller):
        _set_status("STOP THE VEHICLE BEFORE SWITCHING")
        return
    _selected_id = candidate
    if _apply_selected(scene):
        _applied_scene_id = scene.get_instance_id()

func _build_ui() -> void:
    _root = Control.new()
    _root.name = "VehicleSelectorUI"
    _root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    _root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(_root)

    _button = Button.new()
    _button.text = "CAR"
    _button.position = Vector2(18, 18)
    _button.size = Vector2(82, 44)
    _button.focus_mode = Control.FOCUS_NONE
    _button.pressed.connect(func() -> void: _panel.visible = not _panel.visible)
    _root.add_child(_button)

    _panel = PanelContainer.new()
    _panel.position = Vector2(18, 72)
    _panel.size = Vector2(390, 190)
    _panel.visible = false
    _panel.mouse_filter = Control.MOUSE_FILTER_STOP
    _root.add_child(_panel)

    var rows := VBoxContainer.new()
    rows.add_theme_constant_override("separation", 8)
    _panel.add_child(rows)

    var title := Label.new()
    title.text = "VEHICLES — VERIFIED MEDIA ONLY"
    rows.add_child(title)

    _selector = OptionButton.new()
    _selector.custom_minimum_size.y = 44
    rows.add_child(_selector)

    var actions := HBoxContainer.new()
    rows.add_child(actions)
    var apply := Button.new()
    apply.text = "USE VEHICLE"
    apply.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    apply.pressed.connect(_select_current)
    actions.add_child(apply)
    var close := Button.new()
    close.text = "CLOSE"
    close.pressed.connect(func() -> void: _panel.visible = false)
    actions.add_child(close)

    _status = Label.new()
    _status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    rows.add_child(_status)
    _refresh_eligible()

func _sync_selector() -> void:
    if _selector == null:
        return
    for index in range(_selector.item_count):
        if str(_selector.get_item_metadata(index)) == _selected_id:
            _selector.select(index)
            return

func _set_status(value: String) -> void:
    if _status != null and _status.text != value:
        _status.text = value

func _load_selection() -> void:
    if not FileAccess.file_exists(SETTINGS_PATH):
        return
    var parsed = JSON.parse_string(FileAccess.get_file_as_string(SETTINGS_PATH))
    if parsed is Dictionary:
        var candidate := str(parsed.get("vehicle_id", CROWN_ID))
        if Catalog.has(candidate):
            _selected_id = candidate

func _save_selection() -> void:
    DirAccess.make_dir_recursive_absolute(SETTINGS_PATH.get_base_dir())
    var file := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
    if file != null:
        file.store_string(JSON.stringify({"vehicle_id": _selected_id}))
