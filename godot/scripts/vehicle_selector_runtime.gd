extends CanvasLayer

signal vehicle_selected(vehicle_id: String)

const Catalog = preload("res://scripts/vehicle_catalog.gd")
const STARTER_VEHICLE_ID := "toyota_crown"
const SCRAPPED_IDS := ["toyota_mark_x", "port_royal_992"]

var _selected_id := STARTER_VEHICLE_ID
var _applied_scene_id := 0
var _applied_controller_id := 0
var _button: Button
var _panel: PanelContainer
var _selector: OptionButton
var _status: Label

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    layer = 90
    _build_ui()
    _sync_selector()

func _process(_delta: float) -> void:
    var scene := get_tree().current_scene
    var controller := _scene_controller(scene)
    var scene_id := scene.get_instance_id() if is_instance_valid(scene) else 0
    var controller_id := controller.get_instance_id() if is_instance_valid(controller) else 0
    if scene_id != _applied_scene_id or controller_id != _applied_controller_id:
        if apply_selected_to_scene(scene):
            vehicle_selected.emit(_selected_id)

func available_vehicle_ids() -> Array:
    var result: Array = []
    for vehicle_id in Catalog.production_ids():
        var value := str(vehicle_id)
        if SCRAPPED_IDS.has(value):
            continue
        if not result.has(value):
            result.append(value)
    if not result.has(STARTER_VEHICLE_ID):
        result.push_front(STARTER_VEHICLE_ID)
    return result

func selected_vehicle_id() -> String:
    return _selected_id

func owned_vehicle_ids() -> Array[String]:
    var result: Array[String] = []
    for vehicle_id in available_vehicle_ids():
        result.append(str(vehicle_id))
    return result

func is_vehicle_owned(vehicle_id: String) -> bool:
    return available_vehicle_ids().has(vehicle_id)

static func vehicle_price_jmd(_vehicle_id: String) -> int:
    return 0

func wallet_jmd() -> int:
    return 0

func can_afford_vehicle(vehicle_id: String) -> bool:
    return is_vehicle_owned(vehicle_id)

func set_selected_vehicle(vehicle_id: String, _persist: bool = true, apply_to_game: bool = true) -> bool:
    if SCRAPPED_IDS.has(vehicle_id) or not available_vehicle_ids().has(vehicle_id):
        _set_status("VEHICLE UNAVAILABLE")
        return false
    var scene := get_tree().current_scene
    var controller := _scene_controller(scene)
    if apply_to_game and controller != null:
        var speed := absf(float(controller.get("speed_mps")))
        if speed > 0.75:
            _set_status("STOP THE VEHICLE BEFORE SWITCHING")
            return false
        controller.call("apply_profile", vehicle_id)
        _remember_applied(scene, controller)
    _selected_id = vehicle_id
    _sync_selector()
    _set_status(_display_name(vehicle_id))
    vehicle_selected.emit(vehicle_id)
    return true

func apply_selected_to_scene(scene) -> bool:
    var controller := _scene_controller(scene)
    if controller == null or not controller.has_method("apply_profile"):
        return false
    if SCRAPPED_IDS.has(_selected_id) or not available_vehicle_ids().has(_selected_id):
        _selected_id = STARTER_VEHICLE_ID
    if str(controller.get("vehicle_id")) != _selected_id:
        controller.call("apply_profile", _selected_id)
    _remember_applied(scene, controller)
    _sync_selector()
    return true

func open_garage() -> void:
    if _panel != null:
        _panel.visible = true
        _sync_selector()

func close_garage() -> void:
    if _panel != null:
        _panel.visible = false

func is_open() -> bool:
    return _panel != null and _panel.visible

func _cycle_vehicle() -> void:
    var ids := available_vehicle_ids()
    if ids.is_empty():
        return
    var index := ids.find(_selected_id)
    var next_id := str(ids[(index + 1) % ids.size()]) if index >= 0 else str(ids[0])
    set_selected_vehicle(next_id, false, true)

func _scene_controller(scene) -> Object:
    if scene == null:
        return null
    var value = scene.get("vehicle")
    return value if value is Object else null

func _remember_applied(scene, controller) -> void:
    _applied_scene_id = scene.get_instance_id() if is_instance_valid(scene) else 0
    _applied_controller_id = controller.get_instance_id() if is_instance_valid(controller) else 0

func _build_ui() -> void:
    _button = Button.new()
    _button.text = "CAR"
    _button.position = Vector2(18, 76)
    _button.size = Vector2(112, 42)
    _button.pressed.connect(open_garage)
    add_child(_button)

    _panel = PanelContainer.new()
    _panel.position = Vector2(18, 126)
    _panel.size = Vector2(330, 154)
    _panel.visible = false
    add_child(_panel)

    var column := VBoxContainer.new()
    column.add_theme_constant_override("separation", 8)
    _panel.add_child(column)

    _selector = OptionButton.new()
    _selector.custom_minimum_size.y = 42
    column.add_child(_selector)

    _status = Label.new()
    _status.text = "Select player vehicle"
    column.add_child(_status)

    var row := HBoxContainer.new()
    row.add_theme_constant_override("separation", 8)
    column.add_child(row)

    var apply := Button.new()
    apply.text = "Use vehicle"
    apply.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    apply.pressed.connect(func() -> void:
        if _selector.selected >= 0:
            var ids := available_vehicle_ids()
            if _selector.selected < ids.size() and set_selected_vehicle(str(ids[_selector.selected]), false, true):
                close_garage())
    row.add_child(apply)

    var next := Button.new()
    next.text = "Next"
    next.pressed.connect(_cycle_vehicle)
    row.add_child(next)

    var close := Button.new()
    close.text = "Close"
    close.pressed.connect(close_garage)
    row.add_child(close)

func _sync_selector() -> void:
    if _selector == null:
        return
    var ids := available_vehicle_ids()
    _selector.clear()
    var selected_index := 0
    for index in range(ids.size()):
        var vehicle_id := str(ids[index])
        _selector.add_item(_display_name(vehicle_id))
        if vehicle_id == _selected_id:
            selected_index = index
    if _selector.item_count > 0:
        _selector.select(selected_index)
    if _button != null:
        _button.text = "CAR · " + _display_name(_selected_id)

func _display_name(vehicle_id: String) -> String:
    var profile: Dictionary = Catalog.profile(vehicle_id)
    return str(profile.get("display_name", vehicle_id))

func _set_status(value: String) -> void:
    if _status != null:
        _status.text = value
