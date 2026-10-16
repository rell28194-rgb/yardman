extends CanvasLayer

signal vehicle_selected(vehicle_id: String)

const SANDBOX_MODE := true
const Catalog = preload("res://scripts/vehicle_catalog.gd")
const ModelScript = preload("res://scripts/vehicle_model.gd")
const Styler = preload("res://scripts/vehicle_visual_styler.gd")
const JobPersistence = preload("res://scripts/job_persistence_runtime.gd")
const SETTINGS_PATH := "user://yardman/vehicle.json"

const STARTER_VEHICLE_ID := "toyota_crown"
const VEHICLE_PRICES_JMD := {
    "toyota_crown": 0,
    "toyota_mark_x": 32000,
    "port_royal_992": 95000,
}

var _selected_id := STARTER_VEHICLE_ID
var _owned_ids: Array[String] = [STARTER_VEHICLE_ID]
var _root: Control
var _garage_button: Button
var _panel: PanelContainer
var _modal: ColorRect
var _selector: OptionButton
var _info: Label
var _status: Label
var _apply_button: Button
var _preview_viewport: SubViewport
var _preview_root: Node3D
var _preview_model: Node3D
var _initial_applied := false
var _paused_by_garage := false
var _applied_scene_id := 0
var _applied_controller_id := 0
var _preview_built_id := ""
var _last_selection_error := ""

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    layer = 90
    _load_selection()
    _build_ui()

func _process(delta: float) -> void:
    if is_open() and is_instance_valid(_preview_model):
        _preview_model.rotate_y(delta * 0.30)
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
    elif key not in [KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_TAB, KEY_ENTER, KEY_KP_ENTER, KEY_SPACE, KEY_SHIFT]:
        get_viewport().set_input_as_handled()

func available_vehicle_ids() -> Array:
    return Catalog.production_ids()

func selected_vehicle_id() -> String:
    return _selected_id

func owned_vehicle_ids() -> Array[String]:
    var result: Array[String] = []
    for vehicle_id in _owned_ids:
        result.append(vehicle_id)
    return result

static func vehicle_price_jmd(vehicle_id: String) -> int:
    return maxi(0, int(VEHICLE_PRICES_JMD.get(vehicle_id, 0)))

static func normalized_owned_ids(value: Variant, selected_id: String) -> Array[String]:
    var result: Array[String] = [STARTER_VEHICLE_ID]
    if value is Array:
        for entry in value:
            var vehicle_id := str(entry)
            if Catalog.production_ids().has(vehicle_id) and not result.has(vehicle_id):
                result.append(vehicle_id)
    if Catalog.production_ids().has(selected_id) and not result.has(selected_id):
        result.append(selected_id)
    return result

func is_vehicle_owned(vehicle_id: String) -> bool:
    return Catalog.production_ids().has(vehicle_id) if SANDBOX_MODE else _owned_ids.has(vehicle_id)

func wallet_jmd() -> int:
    var runtime := get_node_or_null("/root/JobRuntime")
    if runtime == null:
        return 0
    var value = runtime.get("wallet_jmd")
    if not (value is int or value is float) or not is_finite(float(value)):
        return 0
    return maxi(0, int(value))

func can_afford_vehicle(vehicle_id: String) -> bool:
    if is_vehicle_owned(vehicle_id):
        return true
    return wallet_jmd() >= vehicle_price_jmd(vehicle_id)

func last_selection_error() -> String:
    return _last_selection_error

func is_open() -> bool:
    return is_instance_valid(_panel) and _panel.visible

func set_selected_vehicle(vehicle_id: String, persist: bool = true, apply_to_game: bool = true) -> bool:
    _last_selection_error = ""
    if not Catalog.production_ids().has(vehicle_id) or not is_vehicle_owned(vehicle_id):
        _last_selection_error = "VEHICLE UNAVAILABLE"
        return false
    var scene := get_tree().current_scene
    var controller: Object = _scene_controller(scene)
    if apply_to_game:
        if controller == null or not controller.has_method("apply_profile"):
            _last_selection_error = "VEHICLE NOT READY"
            return false
        if not _switch_allowed(scene):
            _last_selection_error = "STOP THE VEHICLE BEFORE SWITCHING"
            return false
    if persist and _stage_selection(vehicle_id) != OK:
        _last_selection_error = "COULD NOT SAVE VEHICLE SELECTION"
        return false
    var previous_controller_id := _controller_vehicle_id(controller, _selected_id)
    if apply_to_game and not _apply_vehicle_to_scene(scene, vehicle_id):
        _discard_staged_selection()
        _last_selection_error = "VEHICLE SWITCH FAILED"
        if not _restore_controller(scene, previous_controller_id):
            _last_selection_error = "VEHICLE SWITCH FAILED — RELOAD REQUIRED"
        return false
    if persist and _commit_staged_selection() != OK:
        _discard_staged_selection()
        _last_selection_error = "COULD NOT SAVE VEHICLE SELECTION"
        if apply_to_game and not _restore_controller(scene, previous_controller_id):
            _last_selection_error = "VEHICLE SWITCH FAILED — RELOAD REQUIRED"
        return false
    _selected_id = vehicle_id
    if apply_to_game:
        _remember_applied_scene(scene)
    _sync_selector()
    _refresh_preview()
    if apply_to_game:
        vehicle_selected.emit(_selected_id)
    return true

func purchase_vehicle(vehicle_id: String, apply_to_game: bool = true) -> bool:
    if SANDBOX_MODE:
        return set_selected_vehicle(vehicle_id, true, apply_to_game)
    _last_selection_error = "ECONOMY DISABLED"
    return false

func _scene_controller(scene: Node) -> Object:
    if not is_instance_valid(scene):
        return null
    var controller = scene.get("vehicle")
    return controller if controller is Object and is_instance_valid(controller) else null

func _controller_vehicle_id(controller: Object, fallback: String) -> String:
    if is_instance_valid(controller):
        var candidate = controller.get("vehicle_id")
        if candidate is String and Catalog.has(candidate):
            return candidate
    return fallback

func _apply_vehicle_to_scene(scene: Node, vehicle_id: String) -> bool:
    var controller: Object = _scene_controller(scene)
    if controller == null or not controller.has_method("apply_profile"):
        return false
    var result = controller.call("apply_profile", vehicle_id)
    if result is bool and not result:
        return false
    var active_id = controller.get("vehicle_id")
    return active_id == vehicle_id if active_id != null else result == null or result == true

func _restore_controller(scene: Node, vehicle_id: String) -> bool:
    var controller: Object = _scene_controller(scene)
    if controller == null:
        return false
    if controller.get("vehicle_id") == vehicle_id:
        return true
    return _apply_vehicle_to_scene(scene, vehicle_id)

func _remember_applied_scene(scene: Node) -> void:
    if scene != get_tree().current_scene:
        return
    var controller: Object = _scene_controller(scene)
    _applied_scene_id = scene.get_instance_id()
    _applied_controller_id = controller.get_instance_id() if controller != null else 0
    _initial_applied = true

func apply_selected_to_scene(scene: Node) -> bool:
    if not _switch_allowed(scene) or not _apply_vehicle_to_scene(scene, _selected_id):
        return false
    _remember_applied_scene(scene)
    return true

func open_garage() -> void:
    if _panel == null or is_open():
        return
    _modal.visible = true
    _panel.visible = true
    _garage_button.disabled = true
    _sync_selector()
    _refresh_preview()
    _preview_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
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
    if _preview_viewport != null:
        _preview_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
    if _selector != null:
        _selector.get_popup().hide()
    if _paused_by_garage:
        get_tree().paused = false
        _paused_by_garage = false

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

func _build_ui() -> void:
    _root = Control.new()
    _root.name = "GarageUI"
    _root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    _root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(_root)
    _garage_button = Button.new()
    _garage_button.name = "GarageButton"
    _garage_button.text = "GARAGE"
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
    _modal.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    _modal.color = Color(0.01, 0.016, 0.025, 0.84)
    _modal.mouse_filter = Control.MOUSE_FILTER_STOP
    _modal.visible = false
    _root.add_child(_modal)
    _panel = PanelContainer.new()
    _panel.set_anchor(SIDE_LEFT, 0.5)
    _panel.set_anchor(SIDE_RIGHT, 0.5)
    _panel.set_anchor(SIDE_TOP, 0.5)
    _panel.set_anchor(SIDE_BOTTOM, 0.5)
    _panel.offset_left = -440.0
    _panel.offset_right = 440.0
    _panel.offset_top = -270.0
    _panel.offset_bottom = 270.0
    _panel.mouse_filter = Control.MOUSE_FILTER_STOP
    _panel.visible = false
    _root.add_child(_panel)
    var outer := VBoxContainer.new()
    _panel.add_child(outer)
    var title := Label.new()
    title.text = "YARDMAN VEHICLE GARAGE — SANDBOX"
    outer.add_child(title)
    _selector = OptionButton.new()
    for vehicle_id in Catalog.production_ids():
        _selector.add_item(str(Catalog.profile(vehicle_id).display_name))
        _selector.set_item_metadata(_selector.item_count - 1, vehicle_id)
    _selector.item_selected.connect(func(_index: int): _refresh_preview())
    outer.add_child(_selector)
    _info = Label.new()
    outer.add_child(_info)
    _preview_viewport = SubViewport.new()
    _preview_viewport.size = Vector2i(720, 280)
    _preview_viewport.transparent_bg = true
    _preview_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
    outer.add_child(_preview_viewport)
    _preview_root = Node3D.new()
    _preview_viewport.add_child(_preview_root)
    var camera := Camera3D.new()
    camera.position = Vector3(4.6, 2.2, 6.8)
    camera.look_at_from_position(camera.position, Vector3(0, 0.8, 0))
    _preview_viewport.add_child(camera)
    var light := DirectionalLight3D.new()
    light.rotation_degrees = Vector3(-38, -28, 0)
    _preview_viewport.add_child(light)
    var texture_rect := TextureRect.new()
    texture_rect.custom_minimum_size = Vector2(720, 280)
    texture_rect.texture = _preview_viewport.get_texture()
    texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
    texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
    outer.add_child(texture_rect)
    _status = Label.new()
    outer.add_child(_status)
    _apply_button = Button.new()
    _apply_button.text = "USE THIS VEHICLE"
    _apply_button.pressed.connect(_apply_from_selector)
    outer.add_child(_apply_button)
    var close_button := Button.new()
    close_button.text = "CLOSE"
    close_button.pressed.connect(close_garage)
    outer.add_child(close_button)
    _sync_selector()
    _refresh_preview()

func _preview_id() -> String:
    if _selector == null or _selector.item_count == 0:
        return _selected_id
    var metadata = _selector.get_item_metadata(_selector.selected)
    return str(metadata) if metadata != null else _selected_id

func _sync_selector() -> void:
    if _selector == null:
        return
    for index in range(_selector.item_count):
        if str(_selector.get_item_metadata(index)) == _selected_id:
            _selector.select(index)
            return

func _refresh_preview() -> void:
    if _preview_root == null or _selector == null or _info == null:
        return
    var preview_id := _preview_id()
    var data := Catalog.profile(preview_id)
    var top_kmh := float(data.max_forward_mps) * 3.6
    _info.text = "%s\n%s • %s\nSANDBOX • AVAILABLE\n\nMass: %.0f kg\nWheelbase: %.2f m\nTrack: %.2f m\nTop speed: %.0f km/h" % [str(data.display_name), str(data.manufacturer), str(data.drivetrain), float(data.mass_kg), float(data.wheelbase_m), float(data.track_width_m), top_kmh]
    _refresh_action_state()
    if not is_open():
        return
    if is_instance_valid(_preview_model) and _preview_built_id == preview_id:
        return
    if is_instance_valid(_preview_model):
        _preview_model.queue_free()
    _preview_model = ModelScript.new()
    _preview_model.name = "PreviewVehicleModel"
    _preview_root.add_child(_preview_model)
    _preview_model.call("build", str(data.get("hero_scene", "")))
    var scale_data: Array = data.get("visual_scale", [1.0, 1.0, 1.0])
    if not bool(_preview_model.get_meta("yardman_dedicated_vehicle_mesh", false)) and scale_data.size() >= 3:
        _preview_model.scale = Vector3(float(scale_data[0]), float(scale_data[1]), float(scale_data[2]))
    Styler.apply(_preview_model, data)
    _preview_built_id = preview_id

func _refresh_action_state() -> void:
    if _apply_button == null or _status == null:
        return
    var preview_id := _preview_id()
    if not _switch_allowed():
        _apply_button.disabled = true
        _apply_button.text = "STOP VEHICLE"
        _status.text = "STOP THE VEHICLE BEFORE SWITCHING"
        return
    _apply_button.disabled = false
    _apply_button.text = "USE THIS VEHICLE"
    _status.text = "CURRENT VEHICLE" if preview_id == _selected_id else "SANDBOX • READY TO SWITCH"

func _apply_from_selector() -> void:
    var requested := _preview_id()
    if set_selected_vehicle(requested, true, true):
        _status.text = "%s SELECTED" % str(Catalog.profile(requested).display_name).to_upper()
    else:
        _status.text = _last_selection_error

func _load_selection() -> void:
    _selected_id = STARTER_VEHICLE_ID
    _owned_ids.clear()
    for vehicle_id in Catalog.production_ids():
        _owned_ids.append(str(vehicle_id))
    if FileAccess.file_exists(_settings_path()):
        var file := FileAccess.open(_settings_path(), FileAccess.READ)
        if file != null:
            var json := JSON.new()
            if json.parse(file.get_as_text()) == OK and json.data is Dictionary:
                var candidate := str(json.data.get("selected_vehicle", STARTER_VEHICLE_ID))
                if Catalog.production_ids().has(candidate):
                    _selected_id = candidate

func _settings_path() -> String:
    return SETTINGS_PATH

func _stage_path() -> String:
    return SETTINGS_PATH + ".next"

func _stage_selection(vehicle_id: String) -> Error:
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://yardman"))
    var file := FileAccess.open(_stage_path(), FileAccess.WRITE)
    if file == null:
        return FileAccess.get_open_error()
    file.store_string(JSON.stringify({"selected_vehicle": vehicle_id}))
    file.flush()
    return OK

func _commit_staged_selection() -> Error:
    var absolute_stage := ProjectSettings.globalize_path(_stage_path())
    var absolute_target := ProjectSettings.globalize_path(_settings_path())
    if not FileAccess.file_exists(_stage_path()):
        return ERR_FILE_NOT_FOUND
    if FileAccess.file_exists(_settings_path()):
        DirAccess.remove_absolute(absolute_target)
    return DirAccess.rename_absolute(absolute_stage, absolute_target)

func _discard_staged_selection() -> void:
    if FileAccess.file_exists(_stage_path()):
        DirAccess.remove_absolute(ProjectSettings.globalize_path(_stage_path()))
