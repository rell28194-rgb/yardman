extends CanvasLayer

signal vehicle_selected(vehicle_id: String)

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
    # Removing/reloading the garage must not leave its pause behind.
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
        # Leave UI navigation to the focused control. Gameplay/menu shortcuts
        # must not reach always-processing autoloads underneath this modal.
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
        # Legacy vehicle.json files only stored selected_vehicle. Treat that
        # existing selection as owned so an update never takes a car away.
        result.append(selected_id)
    return result

func is_vehicle_owned(vehicle_id: String) -> bool:
    return _owned_ids.has(vehicle_id)

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
    # Prepare a sibling file first. A failed write cannot corrupt the previous
    # selection, and a rejected controller never commits the prepared file.
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
    _last_selection_error = ""
    if not Catalog.production_ids().has(vehicle_id):
        _last_selection_error = "VEHICLE UNAVAILABLE"
        return false
    if is_vehicle_owned(vehicle_id):
        return set_selected_vehicle(vehicle_id, true, apply_to_game)
    if apply_to_game and not _switch_allowed():
        _last_selection_error = "STOP THE VEHICLE BEFORE SWITCHING"
        return false
    var price := vehicle_price_jmd(vehicle_id)
    # The debit and ownership must reach the SAME atomic record. vehicle.json
    # remains a selection/UI cache; a crash before it commits cannot lose a car.
    if price <= 0:
        _last_selection_error = "COULD NOT COMPLETE VEHICLE PAYMENT"
        return false
    if wallet_jmd() < price:
        _last_selection_error = "COULD NOT COMPLETE VEHICLE PAYMENT"
        return false
    var jobs := get_node_or_null("/root/JobRuntime")
    # Seed a wallet+ownership baseline BEFORE the first debit. Otherwise the
    # first purchase's .bak could contain a legacy wallet without ownership and
    # incorrectly grandfather the newer selection cache after backup recovery.
    if jobs == null or (jobs.get("garage_owned_ids") == null and not _save_wallet()):
        _last_selection_error = "COULD NOT COMPLETE VEHICLE PAYMENT"
        return false
    _owned_ids.append(vehicle_id)
    if not _spend_wallet(price):
        _owned_ids.erase(vehicle_id)
        _last_selection_error = "COULD NOT COMPLETE VEHICLE PAYMENT"
        return false
    if not set_selected_vehicle(vehicle_id, true, apply_to_game):
        _owned_ids.erase(vehicle_id)
        if not _refund_wallet(price):
            # The durable purchase still owns the vehicle. Never retain an
            # in-memory refund which failed to reach disk or offer a second debit.
            var runtime := get_node_or_null("/root/JobRuntime")
            _owned_ids = normalized_owned_ids(runtime.get("garage_owned_ids"), STARTER_VEHICLE_ID)
            _refresh_preview()
            _last_selection_error = "PURCHASE SAVED — SELECT YOUR VEHICLE AGAIN"
        return false
    return true

func _wallet_save_path() -> String:
    return "user://yardman/jobs.json"

func _save_wallet() -> bool:
    var runtime := get_node_or_null("/root/JobRuntime")
    var persistence := get_node_or_null("/root/JobPersistenceRuntime")
    if runtime == null or persistence == null:
        return false
    var state = runtime.call("save_snapshot")
    if not state is Dictionary:
        return false
    state["garage_owned_ids"] = owned_vehicle_ids()
    if persistence.call("write_state", _wallet_save_path(), state) != OK:
        return false
    runtime.set("garage_owned_ids", owned_vehicle_ids())
    return true

func _spend_wallet(amount: int) -> bool:
    if amount <= 0 or wallet_jmd() < amount:
        return false
    var runtime := get_node_or_null("/root/JobRuntime")
    var balance := wallet_jmd()
    runtime.set("wallet_jmd", balance - amount)
    if not _save_wallet():
        runtime.set("wallet_jmd", balance)
        return false
    runtime.call("_update_ui")
    return true

func _refund_wallet(amount: int) -> bool:
    var runtime := get_node_or_null("/root/JobRuntime")
    if runtime == null:
        return false
    var balance := wallet_jmd()
    runtime.set("wallet_jmd", balance + amount)
    if not _save_wallet():
        runtime.set("wallet_jmd", balance)
        runtime.call("_update_ui")
        return false
    runtime.call("_update_ui")
    return true

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
    # Older controller adapters return void. When a controller publishes its
    # active profile, verify the result instead of treating a no-op as success.
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

    _modal = ColorRect.new()
    _modal.name = "GarageModal"
    _modal.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    _modal.color = Color(0.01, 0.016, 0.025, 0.84)
    _modal.mouse_filter = Control.MOUSE_FILTER_STOP
    _modal.visible = false
    _root.add_child(_modal)

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
    subtitle.text = "Choose your next drive"
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
    _preview_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
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
    # Metallic surfaces need an environment to reflect even when the visible
    # background is a solid studio colour. Keep this small, static and local to
    # the garage's isolated viewport rather than changing the world lighting.
    var studio_material := ProceduralSkyMaterial.new()
    studio_material.sky_top_color = Color(0.22, 0.24, 0.28)
    studio_material.sky_horizon_color = Color(0.72, 0.74, 0.78)
    studio_material.ground_bottom_color = Color(0.09, 0.10, 0.12)
    studio_material.ground_horizon_color = Color(0.62, 0.64, 0.68)
    var studio_sky := Sky.new()
    studio_sky.radiance_size = Sky.RADIANCE_SIZE_128
    studio_sky.process_mode = Sky.PROCESS_MODE_QUALITY
    studio_sky.sky_material = studio_material
    environment.sky = studio_sky
    environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
    environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
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
    if _selector == null or _selector.item_count == 0 or _selector.selected < 0:
        return _selected_id
    return str(_selector.get_item_metadata(_selector.selected))

func _refresh_preview() -> void:
    if _preview_root == null or _selector == null or _info == null:
        return
    var preview_id := _preview_id()
    var data := Catalog.profile(preview_id)
    var top_kmh := float(data.max_forward_mps) * 3.6
    var ownership_text := "OWNED" if is_vehicle_owned(preview_id) else "PRICE: J$%d" % vehicle_price_jmd(preview_id)
    _info.text = "%s\n%s • %s\n%s • WALLET J$%d\n\nMass: %.0f kg\nWheelbase: %.2f m\nTrack: %.2f m\nTop speed: %.0f km/h" % [
        str(data.display_name), str(data.manufacturer), str(data.drivetrain), ownership_text, wallet_jmd(),
        float(data.mass_kg), float(data.wheelbase_m), float(data.track_width_m), top_kmh
    ]
    _refresh_action_state()
    # Candidate changes while hidden update the text/selection only. GPU work
    # and model allocation start when the garage is actually opened.
    if not is_open():
        return
    if is_instance_valid(_preview_model) and _preview_built_id == preview_id:
        return
    if is_instance_valid(_preview_model):
        _preview_root.remove_child(_preview_model)
        _preview_model.queue_free()
    _preview_model = ModelScript.new()
    _preview_model.name = "PreviewVehicleModel"
    _preview_root.add_child(_preview_model)
    _preview_model.call("build", str(data.get("hero_scene", "")))
    var scale_data: Array = data.get("visual_scale", [1.0, 1.0, 1.0])
    if scale_data.size() >= 3:
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
    if is_vehicle_owned(preview_id):
        _apply_button.disabled = false
        _apply_button.text = "USE THIS VEHICLE"
        _status.text = "CURRENT VEHICLE" if preview_id == _selected_id else "OWNED • READY TO SWITCH"
        return
    var price := vehicle_price_jmd(preview_id)
    var balance := wallet_jmd()
    _apply_button.text = "BUY • J$%d" % price
    if balance >= price:
        _apply_button.disabled = false
        _status.text = "READY TO BUY • WALLET J$%d" % balance
    else:
        _apply_button.disabled = true
        _status.text = "NEED J$%d MORE" % (price - balance)

func _apply_from_selector() -> void:
    if not _switch_allowed():
        _refresh_action_state()
        return
    var requested := _preview_id()
    if is_vehicle_owned(requested):
        if set_selected_vehicle(requested, true, true):
            _status.text = "%s SELECTED" % str(Catalog.profile(requested).display_name).to_upper()
        else:
            _status.text = "VEHICLE SWITCH FAILED"
        return
    if purchase_vehicle(requested, true):
        _status.text = "PURCHASED • %s SELECTED" % str(Catalog.profile(requested).display_name).to_upper()
    else:
        _status.text = _last_selection_error

func _load_selection() -> void:
    _selected_id = STARTER_VEHICLE_ID
    _owned_ids = [STARTER_VEHICLE_ID]
    if FileAccess.file_exists(_settings_path()):
        var file := FileAccess.open(_settings_path(), FileAccess.READ)
        if file != null:
            var json := JSON.new()
            if json.parse(file.get_as_text()) == OK and json.data is Dictionary:
                var parsed: Dictionary = json.data
                var candidate := str(parsed.get("selected_vehicle", STARTER_VEHICLE_ID))
                if Catalog.production_ids().has(candidate):
                    _selected_id = candidate
                _owned_ids = normalized_owned_ids(parsed.get("owned_vehicles", []), _selected_id)
    # Job persistence loads deferred, after this autoload's _ready. Read the
    # same validated primary/backup pair here so recovery has no startup race.
    var state := JobPersistence.read_state(_wallet_save_path())
    if state.has("garage_owned_ids"):
        _owned_ids = normalized_owned_ids(state["garage_owned_ids"], STARTER_VEHICLE_ID)
        if not is_vehicle_owned(_selected_id):
            _selected_id = STARTER_VEHICLE_ID

func _settings_path() -> String:
    return SETTINGS_PATH

func _staged_settings_path() -> String:
    return "%s.pending-%d" % [_settings_path(), get_instance_id()]

func _stage_selection(vehicle_id: String) -> Error:
    var directory := ProjectSettings.globalize_path(_settings_path().get_base_dir())
    var error := DirAccess.make_dir_recursive_absolute(directory)
    if error != OK:
        return error
    var file := FileAccess.open(_staged_settings_path(), FileAccess.WRITE)
    if file == null:
        return FileAccess.get_open_error()
    file.store_string(JSON.stringify({"selected_vehicle": vehicle_id, "owned_vehicles": _owned_ids}, "  "))
    file.flush()
    error = file.get_error()
    file.close()
    if error != OK:
        _discard_staged_selection()
    return error

func _commit_staged_selection() -> Error:
    return DirAccess.rename_absolute(ProjectSettings.globalize_path(_staged_settings_path()), ProjectSettings.globalize_path(_settings_path()))

func _discard_staged_selection() -> void:
    if FileAccess.file_exists(_staged_settings_path()):
        DirAccess.remove_absolute(ProjectSettings.globalize_path(_staged_settings_path()))

func _save_selection() -> bool:
    if _stage_selection(_selected_id) != OK:
        return false
    if _commit_staged_selection() != OK:
        _discard_staged_selection()
        return false
    return true
