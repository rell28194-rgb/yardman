extends CanvasLayer
class_name YardmanStartupMenu

const GAMEPLAY_SCENE := "res://main.tscn"
const ROAD_MANIFEST_PATH := "res://data/roads/manifest.json"
const OPTIONS_PATH := "user://yardman/startup_options.json"
const FALLBACK_PARISHES := [
    "Clarendon",
    "Hanover",
    "Kingston",
    "Manchester",
    "Portland",
    "St. Andrew",
    "St. Ann",
    "St. Catherine",
    "St. Elizabeth",
    "St. James",
    "St. Mary",
    "St. Thomas",
    "Trelawny",
    "Westmoreland",
]
const AI_RUNTIME_NAMES := [
    "TrafficRuntime",
    "PedestrianRuntime",
    "PedestrianDestinationRuntime",
    "PedestrianIdleRuntime",
    "TrafficPedestrianSafetyRuntime",
    "TrafficVisualVarietyRuntime",
    "TrafficBrakeLightRuntime",
    "TrafficHeadlightRuntime",
]
const PREGAME_RUNTIME_NAMES := [
    "RenderRuntime",
    "TerrainPhysicsRuntime",
    "BuildingHLOD",
    "RoadVisibilityRuntime",
    "RoadCorridorTerrainRuntime",
    "RoadEarthworksRuntime",
    "RoadDrainageRuntime",
    "RoadsideEngineeringRuntime",
    "RoadHairpinRuntime",
    "TrafficRuntime",
    "TrafficSignalRuntime",
    "ParkedVehicleRuntime",
    "PedestrianRuntime",
    "PedestrianDestinationRuntime",
    "PedestrianIdleRuntime",
    "TrafficPedestrianSafetyRuntime",
    "TrafficVisualVarietyRuntime",
    "TrafficBrakeLightRuntime",
    "StreetlightNightRuntime",
    "VehicleHeadlightRuntime",
    "TrafficHeadlightRuntime",
    "BuildingNightRuntime",
    "EnvironmentAudioRuntime",
    "VehicleSignalRuntime",
    "JobRuntime",
    "JobPersistenceRuntime",
    "JobGuidanceRuntime",
    "VegetationBudgetRuntime",
    "ReflectionBudgetRuntime",
    "VehicleGarage",
    "VehicleVisualRuntime",
    "VehicleCameraRuntime",
    "SurfaceDynamics",
    "RoadworkLayer",
    "FenceLayer",
    "StreetLightLayer",
    "GuardRailLayer",
    "RetainingWallLayer",
    "BusStopLayer",
    "VehicleDriverLayer",
    "AtmosphereFX",
    "WeatherCycleRuntime",
    "LocationTracker",
]

var game: Node
var screen: Control
var parish_menu: OptionButton
var quality_menu: OptionButton
var continue_button: Button
var garage_button: Button
var ai_toggle: CheckButton
var menu_open := true
var camera_modes := [62.0, 78.0, 92.0]
var camera_mode_index := 1
var _launching_game := false
var _pending_start_parish := ""
var _pending_quality := ""
var _open_garage_after_launch := false
var _ai_enabled := true
var _pregame_process_modes: Dictionary = {}
var _pregame_suspended := false

func _ready() -> void:
    layer = 200
    process_mode = Node.PROCESS_MODE_ALWAYS
    _load_options()
    _suspend_gameplay_runtimes()
    call_deferred("_suspend_gameplay_runtimes")
    _build_ui()
    _populate_parishes_from_manifest()
    _apply_ai_enabled(_ai_enabled)
    _set_open(true)
    call_deferred("_bind_game")
    print("YARDMAN_STARTUP_LAUNCHER_READY")

func _bind_game() -> void:
    var scene := get_tree().current_scene
    if scene == null or not scene.has_method("goto_parish"):
        if _launching_game:
            await get_tree().process_frame
            call_deferred("_bind_game")
        return
    var launched_now := _launching_game
    game = scene
    _launching_game = false
    _restore_gameplay_runtimes()
    if continue_button != null:
        continue_button.disabled = false
        continue_button.text = "CONTINUE DRIVE"
    if garage_button != null:
        garage_button.disabled = false
    _populate_parishes_from_manifest()
    if not _pending_quality.is_empty():
        game.call("set_quality", _pending_quality)
    if not _pending_start_parish.is_empty():
        game.call("goto_parish", _pending_start_parish)
        _pending_start_parish = ""
    _apply_ai_enabled(_ai_enabled)
    if launched_now:
        _set_open(false)
        if _open_garage_after_launch:
            _open_garage_after_launch = false
            call_deferred("_open_vehicle_garage_bound")
    else:
        _set_open(true)
    print("YARDMAN_STARTUP_MENU_BOUND")

func _suspend_gameplay_runtimes() -> void:
    if is_instance_valid(game) or _launching_game:
        return
    for runtime_name in PREGAME_RUNTIME_NAMES:
        var runtime := get_node_or_null("/root/%s" % runtime_name)
        if runtime == null:
            continue
        if not _pregame_process_modes.has(runtime_name):
            _pregame_process_modes[runtime_name] = runtime.process_mode
        runtime.process_mode = Node.PROCESS_MODE_DISABLED
    _pregame_suspended = not _pregame_process_modes.is_empty()

func _restore_gameplay_runtimes() -> void:
    if not _pregame_suspended and _pregame_process_modes.is_empty():
        return
    for runtime_name in _pregame_process_modes.keys():
        var runtime := get_node_or_null("/root/%s" % str(runtime_name))
        if runtime == null:
            continue
        runtime.process_mode = int(_pregame_process_modes[runtime_name])
    _pregame_process_modes.clear()
    _pregame_suspended = false

func _begin_shader_warmup() -> void:
    var warmup := get_node_or_null("/root/ShaderWarmup")
    if warmup != null and warmup.has_method("begin"):
        warmup.call("begin")

func _build_ui() -> void:
    screen = Control.new()
    screen.name = "StartupMenuScreen"
    screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    screen.mouse_filter = Control.MOUSE_FILTER_STOP
    add_child(screen)

    var backdrop := ColorRect.new()
    backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    backdrop.color = Color(0.018, 0.025, 0.032, 0.985)
    backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
    screen.add_child(backdrop)

    var panel := PanelContainer.new()
    panel.set_anchors_preset(Control.PRESET_CENTER)
    panel.offset_left = -340.0
    panel.offset_top = -355.0
    panel.offset_right = 340.0
    panel.offset_bottom = 355.0
    screen.add_child(panel)

    var margin := MarginContainer.new()
    margin.add_theme_constant_override("margin_left", 34)
    margin.add_theme_constant_override("margin_right", 34)
    margin.add_theme_constant_override("margin_top", 20)
    margin.add_theme_constant_override("margin_bottom", 20)
    panel.add_child(margin)

    var stack := VBoxContainer.new()
    stack.add_theme_constant_override("separation", 9)
    margin.add_child(stack)

    var title := Label.new()
    title.text = "YARDMAN"
    title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    title.add_theme_font_size_override("font_size", 44)
    stack.add_child(title)

    var subtitle := Label.new()
    subtitle.text = "JAMAICA • INTERNAL TEST DRIVE"
    subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    subtitle.add_theme_font_size_override("font_size", 17)
    stack.add_child(subtitle)

    var rule := HSeparator.new()
    stack.add_child(rule)

    continue_button = Button.new()
    continue_button.text = "CONTINUE DRIVE"
    continue_button.custom_minimum_size = Vector2(0, 52)
    continue_button.pressed.connect(_continue_drive)
    stack.add_child(continue_button)

    garage_button = Button.new()
    garage_button.name = "StartupGarageButton"
    garage_button.text = "VEHICLE GARAGE"
    garage_button.tooltip_text = "Choose, preview or switch vehicles"
    garage_button.custom_minimum_size = Vector2(0, 44)
    garage_button.pressed.connect(_open_vehicle_garage)
    stack.add_child(garage_button)

    var start_button := Button.new()
    start_button.text = "START / RESTART SELECTED PARISH"
    start_button.custom_minimum_size = Vector2(0, 44)
    start_button.pressed.connect(_start_selected_parish)
    stack.add_child(start_button)

    var parish_label := Label.new()
    parish_label.text = "STARTING PARISH"
    stack.add_child(parish_label)
    parish_menu = OptionButton.new()
    parish_menu.custom_minimum_size = Vector2(0, 40)
    stack.add_child(parish_menu)

    var quality_label := Label.new()
    quality_label.text = "GRAPHICS PROFILE"
    stack.add_child(quality_label)
    quality_menu = OptionButton.new()
    quality_menu.custom_minimum_size = Vector2(0, 40)
    for profile in ["Performance", "Balanced", "Quality"]:
        quality_menu.add_item(profile)
    quality_menu.select(1)
    quality_menu.item_selected.connect(_quality_selected)
    stack.add_child(quality_menu)

    ai_toggle = CheckButton.new()
    ai_toggle.text = "WORLD AI — traffic + pedestrians"
    ai_toggle.tooltip_text = "Disable active traffic and pedestrian simulation for performance testing"
    ai_toggle.button_pressed = _ai_enabled
    ai_toggle.custom_minimum_size = Vector2(0, 36)
    ai_toggle.toggled.connect(_ai_toggled)
    stack.add_child(ai_toggle)

    var controls_title := Label.new()
    controls_title.text = "KEYBOARD"
    controls_title.add_theme_font_size_override("font_size", 18)
    stack.add_child(controls_title)

    var controls := Label.new()
    controls.text = "WASD / Arrows  Drive + walk    •    Space  Handbrake / drift\nLeft Ctrl  Drift assist / clutch-kick    •    Shift  Sprint\nE  Enter / exit vehicle    •    C  Recenter camera    •    V  Camera FOV\nM / Esc  Menu    •    R  Recover    •    F5  Save"
    controls.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    controls.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    controls.add_theme_font_size_override("font_size", 15)
    stack.add_child(controls)

    var note := Label.new()
    note.text = "The Jamaica runtime stays unloaded until you start driving. AI can be disabled independently for clean performance tests."
    note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    note.modulate = Color(0.74, 0.78, 0.82)
    stack.add_child(note)

func _populate_parishes_from_manifest() -> void:
    if parish_menu == null:
        return
    var names: Array = []
    if FileAccess.file_exists(ROAD_MANIFEST_PATH):
        var payload = JSON.parse_string(FileAccess.get_file_as_string(ROAD_MANIFEST_PATH))
        if payload is Dictionary:
            var anchors: Dictionary = payload.get("parish_anchors", {})
            names = anchors.keys()
    if names.is_empty():
        names = FALLBACK_PARISHES.duplicate()
    names.sort()
    var desired := _pending_start_parish
    if desired.is_empty() and is_instance_valid(game):
        desired = str(game.get("current_parish"))
    if desired.is_empty():
        desired = "St. Mary"
    parish_menu.clear()
    var selected := 0
    for index in range(names.size()):
        parish_menu.add_item(str(names[index]))
        if str(names[index]) == desired:
            selected = index
    if parish_menu.item_count > 0:
        parish_menu.select(selected)

func _quality_selected(index: int) -> void:
    if index < 0 or index >= quality_menu.item_count:
        return
    _pending_quality = quality_menu.get_item_text(index)
    if is_instance_valid(game):
        game.call("set_quality", _pending_quality)

func _continue_drive() -> void:
    if is_instance_valid(game):
        _set_open(false)
        return
    _pending_start_parish = ""
    _launch_game()

func _open_vehicle_garage() -> void:
    if not is_instance_valid(game):
        _open_garage_after_launch = true
        _pending_start_parish = ""
        _launch_game()
        return
    _open_vehicle_garage_bound()

func _open_vehicle_garage_bound() -> void:
    var garage := get_node_or_null("/root/VehicleGarage")
    if garage == null or not garage.has_method("open_garage"):
        if is_instance_valid(game) and game.has_method("_notify"):
            game.call("_notify", "Garage unavailable")
        return
    _set_open(false)
    garage.call("open_garage")

func _start_selected_parish() -> void:
    if parish_menu.item_count > 0:
        _pending_start_parish = parish_menu.get_item_text(parish_menu.selected)
    if is_instance_valid(game):
        if not _pending_start_parish.is_empty():
            game.call("goto_parish", _pending_start_parish)
            _pending_start_parish = ""
        _set_open(false)
        return
    _launch_game()

func _launch_game() -> void:
    if _launching_game:
        return
    _launching_game = true
    if continue_button != null:
        continue_button.disabled = true
        continue_button.text = "LOADING JAMAICA…"
    if garage_button != null:
        garage_button.disabled = true
    _begin_shader_warmup()
    var error := get_tree().change_scene_to_file(GAMEPLAY_SCENE)
    if error != OK:
        _launching_game = false
        if continue_button != null:
            continue_button.disabled = false
            continue_button.text = "CONTINUE DRIVE"
        if garage_button != null:
            garage_button.disabled = false
        push_error("Could not launch Yardman gameplay scene: %s" % error_string(error))
        return
    call_deferred("_bind_game")

func _ai_toggled(enabled: bool) -> void:
    _ai_enabled = enabled
    _apply_ai_enabled(enabled)
    _save_options()
    if is_instance_valid(game) and game.has_method("_notify"):
        game.call("_notify", "World AI enabled" if enabled else "World AI disabled")

func _apply_ai_enabled(enabled: bool) -> void:
    for runtime_name in AI_RUNTIME_NAMES:
        var runtime := get_node_or_null("/root/%s" % runtime_name)
        if runtime == null:
            continue
        runtime.set_process(enabled)
        runtime.set_physics_process(enabled)
        if not enabled and runtime.has_method("_clear_scene_state"):
            runtime.call("_clear_scene_state")

func _load_options() -> void:
    if not FileAccess.file_exists(OPTIONS_PATH):
        return
    var payload = JSON.parse_string(FileAccess.get_file_as_string(OPTIONS_PATH))
    if payload is Dictionary:
        _ai_enabled = bool(payload.get("ai_enabled", true))

func _save_options() -> void:
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://yardman"))
    var file := FileAccess.open(OPTIONS_PATH, FileAccess.WRITE)
    if file == null:
        return
    file.store_string(JSON.stringify({"ai_enabled": _ai_enabled}))
    file.flush()

func _set_open(open: bool) -> void:
    if not open and not is_instance_valid(game):
        return
    menu_open = open
    if screen != null:
        screen.visible = open
    if is_instance_valid(game):
        game.set("_app_active", not open)
        var vehicle = game.get("vehicle")
        if vehicle != null and open:
            vehicle.set("drift_assist", false)
            vehicle.set("handbrake", false)

func _process(_delta: float) -> void:
    if not is_instance_valid(game):
        return
    var vehicle = game.get("vehicle")
    if vehicle != null:
        vehicle.set("drift_assist", not menu_open and Input.is_physical_key_pressed(KEY_CTRL))

func _unhandled_input(event: InputEvent) -> void:
    if not event is InputEventKey or not event.pressed or event.echo:
        return
    var key: int = int(event.physical_keycode)
    if key == KEY_ESCAPE or key == KEY_M:
        if is_instance_valid(game):
            _set_open(not menu_open)
            get_viewport().set_input_as_handled()
        return
    if menu_open or not is_instance_valid(game):
        return
    if key == KEY_C:
        game.set("camera_orbit", 0.0)
        game.set("camera_pitch", -0.20)
        var car = game.get("car") as Node3D
        if car != null:
            game.set("camera_yaw", car.rotation.y)
        game.call("_notify", "Camera recentered")
        get_viewport().set_input_as_handled()
    elif key == KEY_V:
        camera_mode_index = (camera_mode_index + 1) % camera_modes.size()
        var camera = game.get("camera") as Camera3D
        if camera != null:
            camera.fov = float(camera_modes[camera_mode_index])
            game.call("_notify", "Camera FOV %d°" % int(camera.fov))
        get_viewport().set_input_as_handled()
