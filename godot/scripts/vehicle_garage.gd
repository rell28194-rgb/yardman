extends CanvasLayer

signal vehicle_selected(vehicle_id: String)

const Catalog = preload("res://scripts/vehicle_catalog.gd")
const ModelScript = preload("res://scripts/vehicle_model.gd")
const SETTINGS_PATH := "user://yardman/vehicle.json"

var _selected_id := "toyota_crown"
var _root: Control
var _garage_button: Button
var _panel: PanelContainer
var _selector: OptionButton
var _info: Label
var _status: Label
var _apply_button: Button
var _preview_viewport: SubViewport
var _preview_root: Node3D
var _preview_model: Node3D
var _initial_applied := false
var _paused_by_garage := false

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    layer = 90
    _load_selection()
    _build_ui()

func _process(delta: float) -> void:
    if _preview_model != null and _panel != null and _panel.visible:
        _preview_model.rotate_y(delta * 0.30)
    if not _initial_applied:
        var scene := get_tree().current_scene
        if scene != null and apply_selected_to_scene(scene):
            _initial_applied = true
            vehicle_selected.emit(_selected_id)

func available_vehicle_ids() -> Array:
    return Catalog.production_ids()

func selected_vehicle_id() -> String:
    return _selected_id

func set_selected_vehicle(vehicle_id: String, persist: bool = true, apply_to_game: bool = true) -> bool:
    if not Catalog.has(vehicle_id) or vehicle_id == Catalog.DEFAULT_ID:
        return false
    _selected_id = vehicle_id
    if persist:
        _save_selection()
    _sync_selector()
    _refresh_preview()
    if apply_to_game:
        var applied := apply_selected_to_scene(get_tree().current_scene)
        if applied:
            vehicle_selected.emit(_selected_id)
        return applied
    return true

func apply_selected_to_scene(scene: Node) -> bool:
    if scene == null:
        return false
    var controller = scene.get("vehicle")
    if controller == null or not controller.has_method("apply_profile"):
        return false
    controller.call("apply_profile", _selected_id)
    return true

func open_garage() -> void:
    if _panel == null:
        return
    _panel.visible = true
    _sync_selector()
    _refresh_preview()
    var allowed := _switch_allowed()
    _apply_button.disabled = not allowed
    _status.text = "READY TO SWITCH" if allowed else "STOP THE VEHICLE BEFORE SWITCHING"
    if not get_tree().paused:
        get_tree().paused = true
        _paused_by_garage = true

func close_garage() -> void:
    if _panel != null:
        _panel.visible = false
    if _paused_by_garage:
        get_tree().paused = false
        _paused_by_garage = false

func _switch_allowed() -> bool:
    var scene := get_tree().current_scene
    if scene == null:
        return true
    var controller = scene.get("vehicle")
    if controller == null:
        return true
    var speed_value = controller.get("speed_mps")
    if speed_value == null:
        return true
    return absf(float(speed_value)) <= 1.5

func _build_ui() -> void:
    _root = Control.new()
    _root.name = "GarageUI"
    _root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    _root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(_root)

    _garage_button = Button.new()
    _garage_button.name = "GarageButton"
    _garage_button.text = "GARAGE"
    _garage_button.tooltip_text = "Open vehicle selection"
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

    _panel = PanelContainer.new()
    _panel.name = "GaragePanel"
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
    outer.add_theme_constant_override("separation", 10)
    _panel.add_child(outer)

    var title := Label.new()
    title.text = "YARDMAN VEHICLE GARAGE"
    title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    title.add_theme_font_size_override("font_size", 26)
    outer.add_child(title)

    var subtitle := Label.new()
    subtitle.text = "Distinct handling profiles • selection persists across launches"
    subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    outer.add_child(subtitle)

    var content := HBoxContainer.new()
    content.add_theme_constant_override("separation", 16)
    content.size_flags_vertical = Control.SIZE_EXPAND_FILL
    outer.add_child(content)

    var preview_host := SubViewportContainer.new()
    preview_host.name = "VehiclePreview"
    preview_host.custom_minimum_size = Vector2(500.0, 330.0)
    preview_host.stretch = true
    preview_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    preview_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
    content.add_child(preview_host)

    _preview_viewport = SubViewport.new()
    _preview_viewport.name = "PreviewViewport"
    _preview_viewport.size = Vector2i(640, 360)
    _preview_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
    _preview_viewport.own_world_3d = true
    preview_host.add_child(_preview_viewport)
    _build_preview_world()

    var side := VBoxContainer.new()
    side.custom_minimum_size = Vector2(315.0, 330.0)
    side.add_theme_constant_override("separation", 12)
    content.add_child(side)

    var choose := Label.new()
    choose.text = "SELECT VEHICLE"
    side.add_child(choose)

    _selector = OptionButton.new()
    _selector.name = "VehicleSelector"
    _selector.custom_minimum_size = Vector2(300.0, 50.0)
    for vehicle_id in Catalog.production_ids():
        var data := Catalog.profile(str(vehicle_id))
        _selector.add_item(str(data.display_name))
        _selector.set_item_metadata(_selector.item_count - 1, str(vehicle_id))
    _selector.item_selected.connect(_on_preview_selected)
    side.add_child(_selector)

    _info = Label.new()
    _info.name = "VehicleInfo"
    _info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _info.size_flags_vertical = Control.SIZE_EXPAND_FILL
    side.add_child(_info)

    _status = Label.new()
    _status.name = "GarageStatus"
    _status.text = "READY TO SWITCH"
    _status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    side.add_child(_status)

    _apply_button = Button.new()
    _apply_button.name = "ApplyVehicle"
    _apply_button.text = "USE THIS VEHICLE"
    _apply_button.custom_minimum_size = Vector2(300.0, 54.0)
    _apply_button.pressed.connect(_apply_from_selector)
    side.add_child(_apply_button)

    var close_button := Button.new()
    close_button.name = "CloseGarage"
    close_button.text = "CLOSE"
    close_button.custom_minimum_size = Vector2(300.0, 48.0)
    close_button.pressed.connect(close_garage)
    side.add_child(close_button)

    _sync_selector()
    _refresh_preview()

func _build_preview_world() -> void:
    _preview_root = Node3D.new()
    _preview_root.name = "PreviewWorld"
    _preview_viewport.add_child(_preview_root)

    var environment := Environment.new()
    environment.background_mode = Environment.BG_COLOR
    environment.background_color = Color(0.025, 0.032, 0.040)
    environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    environment.ambient_light_color = Color(0.52, 0.58, 0.66)
    environment.ambient_light_energy = 0.75
    var world_environment := WorldEnvironment.new()
    world_environment.environment = environment
    _preview_root.add_child(world_environment)

    var key := DirectionalLight3D.new()
    key.light_energy = 2.0
    key.rotation_degrees = Vector3(-48.0, -32.0, 0.0)
    key.shadow_enabled = true
    _preview_root.add_child(key)

    var fill := OmniLight3D.new()
    fill.position = Vector3(-3.5, 2.8, 3.5)
    fill.light_energy = 4.0
    fill.omni_range = 12.0
    _preview_root.add_child(fill)

    var floor_mesh := PlaneMesh.new()
    floor_mesh.size = Vector2(14.0, 14.0)
    var floor_material := StandardMaterial3D.new()
    floor_material.albedo_color = Color(0.09, 0.105, 0.12)
    floor_material.metallic = 0.15
    floor_material.roughness = 0.42
    floor_mesh.material = floor_material
    var floor_instance := MeshInstance3D.new()
    floor_instance.mesh = floor_mesh
    _preview_root.add_child(floor_instance)

    var camera := Camera3D.new()
    camera.position = Vector3(5.2, 2.6, 7.0)
    camera.fov = 48.0
    camera.current = true
    _preview_root.add_child(camera)
    camera.look_at(Vector3(0.0, 0.85, 0.0), Vector3.UP)

func _sync_selector() -> void:
    if _selector == null:
        return
    for index in range(_selector.item_count):
        if str(_selector.get_item_metadata(index)) == _selected_id:
            _selector.select(index)
            return

func _on_preview_selected(_index: int) -> void:
    _refresh_preview()

func _preview_id() -> String:
    if _selector == null or _selector.item_count == 0:
        return _selected_id
    return str(_selector.get_item_metadata(_selector.selected))

func _refresh_preview() -> void:
    if _preview_root == null or _selector == null or _info == null:
        return
    if _preview_model != null:
        _preview_root.remove_child(_preview_model)
        _preview_model.queue_free()
    var preview_id := _preview_id()
    var data := Catalog.profile(preview_id)
    _preview_model = ModelScript.new()
    _preview_model.name = "PreviewVehicleModel"
    _preview_root.add_child(_preview_model)
    _preview_model.call("build")
    var scale_data: Array = data.get("visual_scale", [1.0, 1.0, 1.0])
    if scale_data.size() >= 3:
        _preview_model.scale = Vector3(float(scale_data[0]), float(scale_data[1]), float(scale_data[2]))
    var top_kmh := float(data.max_forward_mps) * 3.6
    _info.text = "%s\n%s • %s\n\nMass tuning: %.0f kg\nWheelbase: %.2f m\nTrack: %.2f m\nCG height: %.2f m\nTop-speed tuning: %.0f km/h\nAudio profile: %s\n\nCurrent hero mesh status: integration pending" % [
        str(data.display_name), str(data.manufacturer), str(data.drivetrain), float(data.mass_kg), float(data.wheelbase_m),
        float(data.track_width_m), float(data.cg_height_m), top_kmh, str(data.audio_profile)
    ]

func _apply_from_selector() -> void:
    if not _switch_allowed():
        _status.text = "STOP THE VEHICLE BEFORE SWITCHING"
        _apply_button.disabled = true
        return
    var requested := _preview_id()
    if set_selected_vehicle(requested, true, true):
        _status.text = "%s SELECTED" % str(Catalog.profile(requested).display_name).to_upper()
    else:
        _status.text = "VEHICLE SWITCH FAILED"

func _load_selection() -> void:
    if not FileAccess.file_exists(SETTINGS_PATH):
        return
    var file := FileAccess.open(SETTINGS_PATH, FileAccess.READ)
    if file == null:
        return
    var parsed = JSON.parse_string(file.get_as_text())
    if parsed is Dictionary:
        var candidate := str(parsed.get("selected_vehicle", _selected_id))
        if Catalog.has(candidate) and candidate != Catalog.DEFAULT_ID:
            _selected_id = candidate

func _save_selection() -> void:
    var directory := ProjectSettings.globalize_path(SETTINGS_PATH.get_base_dir())
    var error := DirAccess.make_dir_recursive_absolute(directory)
    if error != OK:
        push_warning("VehicleGarage: could not create settings directory (%s)" % error_string(error))
        return
    var file := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
    if file == null:
        push_warning("VehicleGarage: could not open vehicle settings for writing")
        return
    file.store_string(JSON.stringify({"selected_vehicle": _selected_id}, "  "))
    file.flush()
    file.close()
