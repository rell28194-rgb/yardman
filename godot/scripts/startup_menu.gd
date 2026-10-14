extends CanvasLayer
class_name YardmanStartupMenu

var game: Node
var screen: Control
var parish_menu: OptionButton
var quality_menu: OptionButton
var continue_button: Button
var garage_button: Button
var menu_open := true
var camera_modes := [62.0, 78.0, 92.0]
var camera_mode_index := 1

func _ready() -> void:
    layer = 200
    process_mode = Node.PROCESS_MODE_ALWAYS
    _build_ui()
    call_deferred("_bind_game")

func _bind_game() -> void:
    var scene := get_tree().current_scene
    if scene == null or not scene.has_method("goto_parish"):
        await get_tree().process_frame
        call_deferred("_bind_game")
        return
    game = scene
    _populate_parishes()
    _set_open(true)
    print("YARDMAN_STARTUP_MENU_READY")

func _build_ui() -> void:
    screen = Control.new()
    screen.name = "StartupMenuScreen"
    screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    screen.mouse_filter = Control.MOUSE_FILTER_STOP
    add_child(screen)

    var backdrop := ColorRect.new()
    backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    backdrop.color = Color(0.018, 0.025, 0.032, 0.965)
    backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
    screen.add_child(backdrop)

    var panel := PanelContainer.new()
    panel.set_anchors_preset(Control.PRESET_CENTER)
    panel.offset_left = -340.0
    panel.offset_top = -350.0
    panel.offset_right = 340.0
    panel.offset_bottom = 350.0
    screen.add_child(panel)

    var margin := MarginContainer.new()
    margin.add_theme_constant_override("margin_left", 34)
    margin.add_theme_constant_override("margin_right", 34)
    margin.add_theme_constant_override("margin_top", 28)
    margin.add_theme_constant_override("margin_bottom", 28)
    panel.add_child(margin)

    var stack := VBoxContainer.new()
    stack.add_theme_constant_override("separation", 12)
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
    continue_button.custom_minimum_size = Vector2(0, 54)
    continue_button.pressed.connect(func() -> void: _set_open(false))
    stack.add_child(continue_button)

    garage_button = Button.new()
    garage_button.name = "StartupGarageButton"
    garage_button.text = "VEHICLE GARAGE"
    garage_button.tooltip_text = "Choose, preview, purchase or switch vehicles"
    garage_button.custom_minimum_size = Vector2(0, 48)
    garage_button.pressed.connect(_open_vehicle_garage)
    stack.add_child(garage_button)

    var start_button := Button.new()
    start_button.text = "START / RESTART SELECTED PARISH"
    start_button.custom_minimum_size = Vector2(0, 48)
    start_button.pressed.connect(_start_selected_parish)
    stack.add_child(start_button)

    var parish_label := Label.new()
    parish_label.text = "STARTING PARISH"
    stack.add_child(parish_label)
    parish_menu = OptionButton.new()
    parish_menu.custom_minimum_size = Vector2(0, 44)
    stack.add_child(parish_menu)

    var quality_label := Label.new()
    quality_label.text = "GRAPHICS PROFILE"
    stack.add_child(quality_label)
    quality_menu = OptionButton.new()
    quality_menu.custom_minimum_size = Vector2(0, 44)
    for profile in ["Performance", "Balanced", "Quality"]:
        quality_menu.add_item(profile)
    quality_menu.select(1)
    quality_menu.item_selected.connect(_quality_selected)
    stack.add_child(quality_menu)

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
    note.text = "Test build: full Jamaica layout remains geographically authoritative. Visual/detail recovery is still Beta 1 work."
    note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    note.modulate = Color(0.74, 0.78, 0.82)
    stack.add_child(note)

func _populate_parishes() -> void:
    parish_menu.clear()
    var roads = game.get("roads")
    if roads == null:
        return
    var manifest: Dictionary = roads.get("manifest")
    var anchors: Dictionary = manifest.get("parish_anchors", {})
    var names: Array = anchors.keys()
    names.sort()
    var current := str(game.get("current_parish"))
    var selected := 0
    for index in range(names.size()):
        parish_menu.add_item(str(names[index]))
        if str(names[index]) == current:
            selected = index
    if parish_menu.item_count > 0:
        parish_menu.select(selected)

func _quality_selected(index: int) -> void:
    if game == null or index < 0 or index >= quality_menu.item_count:
        return
    game.call("set_quality", quality_menu.get_item_text(index))

func _open_vehicle_garage() -> void:
    var garage := get_node_or_null("/root/VehicleGarage")
    if garage == null or not garage.has_method("open_garage"):
        if game != null and game.has_method("_notify"):
            game.call("_notify", "Garage unavailable")
        return
    _set_open(false)
    garage.call("open_garage")

func _start_selected_parish() -> void:
    if game == null:
        return
    if parish_menu.item_count > 0:
        game.call("goto_parish", parish_menu.get_item_text(parish_menu.selected))
    _set_open(false)

func _set_open(open: bool) -> void:
    menu_open = open
    if screen != null:
        screen.visible = open
    if game != null:
        game.set("_app_active", not open)
        var vehicle = game.get("vehicle")
        if vehicle != null and open:
            vehicle.set("drift_assist", false)
            vehicle.set("handbrake", false)

func _process(_delta: float) -> void:
    if game == null:
        return
    var vehicle = game.get("vehicle")
    if vehicle != null:
        vehicle.set("drift_assist", not menu_open and Input.is_physical_key_pressed(KEY_CTRL))

func _unhandled_input(event: InputEvent) -> void:
    if not event is InputEventKey or not event.pressed or event.echo:
        return
    var key: int = int(event.physical_keycode)
    if key == KEY_ESCAPE or key == KEY_M:
        _set_open(not menu_open)
        get_viewport().set_input_as_handled()
        return
    if menu_open or game == null:
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
