extends Node
class_name YardmanVehicleSignalRuntime

const BLINK_PERIOD_S := 0.72
const SIGNAL_OFF := "off"
const SIGNAL_LEFT := "left"
const SIGNAL_RIGHT := "right"
const SIGNAL_HAZARD := "hazard"

var signal_state := SIGNAL_OFF
var _blink_clock := 0.0
var _cancel_armed := false
var _car_id := 0
var _vehicle_id := ""
var _lamp_root: Node3D
var _left_material: StandardMaterial3D
var _right_material: StandardMaterial3D
var _layer: CanvasLayer
var _controls: HBoxContainer
var _left_button: Button
var _hazard_button: Button
var _right_button: Button

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    _make_controls()

func _process(delta: float) -> void:
    _blink_clock = fmod(_blink_clock + delta, BLINK_PERIOD_S)
    var scene := get_tree().current_scene
    if scene == null:
        _set_controls_visible(false)
        _set_emission(false, false)
        return
    var controller = scene.get("vehicle")
    var car = scene.get("car")
    if controller == null or not car is Node3D:
        _set_controls_visible(false)
        return
    var vehicle_id := str(controller.get("vehicle_id"))
    if _lamp_root == null or not is_instance_valid(_lamp_root) or (car as Node3D).get_instance_id() != _car_id or vehicle_id != _vehicle_id:
        _attach_lamps(car as Node3D, controller)
    var occupied := bool(controller.get("occupied"))
    _set_controls_visible(occupied)
    if not occupied and signal_state != SIGNAL_HAZARD:
        set_signal(SIGNAL_OFF)
    var steering := float(controller.get("steering_angle"))
    var speed := absf(float(controller.get("speed_mps")))
    if signal_state == SIGNAL_LEFT or signal_state == SIGNAL_RIGHT:
        if should_arm_cancel(steering):
            _cancel_armed = true
        elif _cancel_armed and should_auto_cancel(steering, speed):
            set_signal(SIGNAL_OFF)
    var flash := blink_on(_blink_clock)
    _set_emission(flash and (signal_state == SIGNAL_LEFT or signal_state == SIGNAL_HAZARD),
        flash and (signal_state == SIGNAL_RIGHT or signal_state == SIGNAL_HAZARD))
    _update_button_state()

func _unhandled_key_input(event: InputEvent) -> void:
    if not event is InputEventKey or not event.pressed or event.echo:
        return
    match event.physical_keycode:
        KEY_Z:
            toggle_left()
        KEY_X:
            toggle_hazard()
        KEY_C:
            toggle_right()

func toggle_left() -> void:
    set_signal(next_state(signal_state, SIGNAL_LEFT))

func toggle_right() -> void:
    set_signal(next_state(signal_state, SIGNAL_RIGHT))

func toggle_hazard() -> void:
    set_signal(next_state(signal_state, SIGNAL_HAZARD))

func set_signal(value: String) -> void:
    signal_state = value if value in [SIGNAL_OFF, SIGNAL_LEFT, SIGNAL_RIGHT, SIGNAL_HAZARD] else SIGNAL_OFF
    _blink_clock = 0.0
    _cancel_armed = false
    _update_button_state()

static func next_state(current: String, requested: String) -> String:
    if requested not in [SIGNAL_LEFT, SIGNAL_RIGHT, SIGNAL_HAZARD]:
        return SIGNAL_OFF
    return SIGNAL_OFF if current == requested else requested

static func blink_on(clock: float) -> bool:
    var phase := fmod(maxf(clock, 0.0), BLINK_PERIOD_S) / BLINK_PERIOD_S
    return phase < 0.50

static func should_arm_cancel(steering_angle: float) -> bool:
    return absf(steering_angle) >= 0.11

static func should_auto_cancel(steering_angle: float, speed_mps: float) -> bool:
    return absf(steering_angle) <= 0.045 and absf(speed_mps) >= 1.5

static func lamp_positions(dimensions: Vector3) -> Dictionary:
    var half_width := maxf(dimensions.x * 0.5, 0.7)
    var half_length := maxf(dimensions.z * 0.5, 1.6)
    var x := clampf(half_width * 0.82, 0.60, 0.96)
    var y := clampf(dimensions.y * 0.45, 0.48, 0.82)
    var front_z := -half_length - 0.025
    var rear_z := half_length + 0.025
    return {
        "left_front": Vector3(-x, y, front_z),
        "left_rear": Vector3(-x, y, rear_z),
        "right_front": Vector3(x, y, front_z),
        "right_rear": Vector3(x, y, rear_z),
    }

func _attach_lamps(car: Node3D, controller) -> void:
    if _lamp_root != null and is_instance_valid(_lamp_root):
        _lamp_root.queue_free()
    _car_id = car.get_instance_id()
    _vehicle_id = str(controller.get("vehicle_id"))
    _lamp_root = Node3D.new()
    _lamp_root.name = "SignalLampRig"
    car.add_child(_lamp_root)
    _left_material = _signal_material()
    _right_material = _signal_material()
    var profile_value = controller.get("profile")
    var dimensions := Vector3(1.85, 1.30, 4.0)
    if profile_value is Dictionary:
        var values: Array = (profile_value as Dictionary).get("dimensions_m", [1.85, 1.30, 4.0])
        if values.size() >= 3:
            dimensions = Vector3(float(values[0]), float(values[1]), float(values[2]))
    var positions := lamp_positions(dimensions)
    _make_lamp("SignalLeftFront", positions.left_front, _left_material)
    _make_lamp("SignalLeftRear", positions.left_rear, _left_material)
    _make_lamp("SignalRightFront", positions.right_front, _right_material)
    _make_lamp("SignalRightRear", positions.right_rear, _right_material)
    _set_emission(false, false)

func _signal_material() -> StandardMaterial3D:
    var material := StandardMaterial3D.new()
    material.albedo_color = Color(0.82, 0.26, 0.015)
    material.metallic = 0.12
    material.roughness = 0.22
    material.emission_enabled = true
    material.emission = Color(1.0, 0.34, 0.025)
    material.emission_energy_multiplier = 0.05
    return material

func _make_lamp(node_name: String, position_value: Vector3, material: StandardMaterial3D) -> void:
    var mesh := BoxMesh.new()
    mesh.size = Vector3(0.16, 0.10, 0.055)
    var instance := MeshInstance3D.new()
    instance.name = node_name
    instance.mesh = mesh
    instance.position = position_value
    instance.material_override = material
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    _lamp_root.add_child(instance)

func _set_emission(left_on: bool, right_on: bool) -> void:
    if _left_material != null:
        _left_material.emission_energy_multiplier = 3.2 if left_on else 0.05
    if _right_material != null:
        _right_material.emission_energy_multiplier = 3.2 if right_on else 0.05

func _make_controls() -> void:
    _layer = CanvasLayer.new()
    _layer.name = "VehicleSignalControls"
    _layer.layer = 24
    add_child(_layer)
    _controls = HBoxContainer.new()
    _controls.name = "SignalButtons"
    _controls.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
    _controls.position = Vector2(-114.0, -94.0)
    _controls.add_theme_constant_override("separation", 8)
    _layer.add_child(_controls)
    _left_button = _button("L", "Left indicator")
    _hazard_button = _button("HAZ", "Hazard lights")
    _right_button = _button("R", "Right indicator")
    _controls.add_child(_left_button)
    _controls.add_child(_hazard_button)
    _controls.add_child(_right_button)
    _left_button.pressed.connect(toggle_left)
    _hazard_button.pressed.connect(toggle_hazard)
    _right_button.pressed.connect(toggle_right)
    _set_controls_visible(false)

func _button(text_value: String, tooltip_value: String) -> Button:
    var button := Button.new()
    button.text = text_value
    button.tooltip_text = tooltip_value
    button.custom_minimum_size = Vector2(68.0, 48.0)
    button.focus_mode = Control.FOCUS_NONE
    button.toggle_mode = true
    return button

func _set_controls_visible(value: bool) -> void:
    if _controls != null:
        _controls.visible = value

func _update_button_state() -> void:
    if _left_button == null:
        return
    _left_button.set_pressed_no_signal(signal_state == SIGNAL_LEFT)
    _right_button.set_pressed_no_signal(signal_state == SIGNAL_RIGHT)
    _hazard_button.set_pressed_no_signal(signal_state == SIGNAL_HAZARD)

func runtime_snapshot() -> Dictionary:
    return {
        "state": signal_state,
        "blink_on": blink_on(_blink_clock),
        "auto_cancel_armed": _cancel_armed,
        "vehicle_id": _vehicle_id,
        "touch_controls": _controls != null,
    }
