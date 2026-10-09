extends Node3D

const RoadStreamerScript = preload("res://scripts/road_streamer.gd")

var car: CharacterBody3D
var hud_label: Label
var speed := 0.0
var steer := 0.0
var touch_left := false
var touch_right := false
var touch_gas := false
var touch_brake := false

func _ready() -> void:
    _make_environment()
    _make_low_detail_island_base()
    _make_qa_car()
    _make_road_streamer()
    _make_camera()
    _make_hud()

func _make_environment() -> void:
    var world_env := WorldEnvironment.new()
    var env := Environment.new()
    env.background_mode = Environment.BG_COLOR
    env.background_color = Color(0.46, 0.72, 0.92)
    env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    env.ambient_light_color = Color(0.8, 0.85, 0.9)
    env.ambient_light_energy = 0.7
    world_env.environment = env
    add_child(world_env)

    var sun := DirectionalLight3D.new()
    sun.rotation_degrees = Vector3(-55, -35, 0)
    sun.light_energy = 1.4
    sun.shadow_enabled = true
    add_child(sun)

func _make_low_detail_island_base() -> void:
    # Temporary low-detail traversal surface. The road network is geographically
    # real and 1:1; terrain elevation/coastline detail is the next map layer.
    var ground := MeshInstance3D.new()
    var mesh := PlaneMesh.new()
    mesh.size = Vector2(235000.0, 82000.0)
    ground.mesh = mesh
    ground.position = Vector3(-47000.0, -0.05, -3000.0)
    var mat := StandardMaterial3D.new()
    mat.albedo_color = Color(0.18, 0.38, 0.16)
    mat.roughness = 1.0
    ground.material_override = mat
    add_child(ground)

    var body := StaticBody3D.new()
    var shape := CollisionShape3D.new()
    var box := BoxShape3D.new()
    box.size = Vector3(235000.0, 1.0, 82000.0)
    shape.shape = box
    body.position = Vector3(-47000.0, -0.55, -3000.0)
    body.add_child(shape)
    add_child(body)

func _make_road_streamer() -> void:
    var streamer = RoadStreamerScript.new()
    streamer.name = "JamaicaRoadStreamer"
    streamer.target = car
    streamer.load_radius = 2
    add_child(streamer)

func _make_qa_car() -> void:
    # This is intentionally only a traversal/QA vehicle. Handling tuning comes
    # after the map baseline passes island-wide road coverage checks.
    car = CharacterBody3D.new()
    car.name = "RoadQA"
    car.position = Vector3(0, 1.0, 0)

    var body_mesh := MeshInstance3D.new()
    var box := BoxMesh.new()
    box.size = Vector3(1.9, 0.7, 4.2)
    body_mesh.mesh = box
    body_mesh.position.y = 0.55
    var mat := StandardMaterial3D.new()
    mat.albedo_color = Color(0.05, 0.08, 0.12)
    mat.metallic = 0.45
    mat.roughness = 0.28
    body_mesh.material_override = mat
    car.add_child(body_mesh)

    var cabin := MeshInstance3D.new()
    var cabin_mesh := BoxMesh.new()
    cabin_mesh.size = Vector3(1.55, 0.65, 1.9)
    cabin.mesh = cabin_mesh
    cabin.position = Vector3(0, 1.18, 0.2)
    var glass := StandardMaterial3D.new()
    glass.albedo_color = Color(0.10, 0.22, 0.30)
    glass.metallic = 0.2
    glass.roughness = 0.12
    cabin.material_override = glass
    car.add_child(cabin)

    var collider := CollisionShape3D.new()
    var collision_shape := BoxShape3D.new()
    collision_shape.size = Vector3(1.9, 0.7, 4.2)
    collider.shape = collision_shape
    collider.position.y = 0.55
    car.add_child(collider)
    add_child(car)

func _make_camera() -> void:
    var cam := Camera3D.new()
    cam.name = "ChaseCamera"
    cam.position = Vector3(0, 4.3, 8.5)
    cam.rotation_degrees.x = -15
    cam.current = true
    car.add_child(cam)

func _make_hud() -> void:
    var layer := CanvasLayer.new()
    layer.name = "MapQAHUD"
    add_child(layer)

    var root := Control.new()
    root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    root.mouse_filter = Control.MOUSE_FILTER_PASS
    layer.add_child(root)

    hud_label = Label.new()
    hud_label.position = Vector2(18, 18)
    hud_label.add_theme_font_size_override("font_size", 25)
    hud_label.add_theme_color_override("font_color", Color.WHITE)
    hud_label.add_theme_color_override("font_shadow_color", Color.BLACK)
    hud_label.add_theme_constant_override("shadow_offset_x", 2)
    hud_label.add_theme_constant_override("shadow_offset_y", 2)
    root.add_child(hud_label)

    var left := _touch_button("◀", 0.0, 1.0, Vector2(24, -174), Vector2(150, 150))
    left.button_down.connect(_left_down)
    left.button_up.connect(_left_up)
    root.add_child(left)

    var right := _touch_button("▶", 0.0, 1.0, Vector2(190, -174), Vector2(150, 150))
    right.button_down.connect(_right_down)
    right.button_up.connect(_right_up)
    root.add_child(right)

    var brake := _touch_button("BRAKE", 1.0, 1.0, Vector2(-350, -174), Vector2(150, 150))
    brake.button_down.connect(_brake_down)
    brake.button_up.connect(_brake_up)
    root.add_child(brake)

    var gas := _touch_button("GAS", 1.0, 1.0, Vector2(-174, -174), Vector2(150, 150))
    gas.button_down.connect(_gas_down)
    gas.button_up.connect(_gas_up)
    root.add_child(gas)

    var reset := _touch_button("RESET", 1.0, 0.0, Vector2(-174, 24), Vector2(150, 72))
    reset.pressed.connect(_reset_car)
    root.add_child(reset)

func _touch_button(label_text: String, ax: float, ay: float, offset: Vector2, button_size: Vector2) -> Button:
    var b := Button.new()
    b.text = label_text
    b.anchor_left = ax
    b.anchor_right = ax
    b.anchor_top = ay
    b.anchor_bottom = ay
    b.offset_left = offset.x
    b.offset_top = offset.y
    b.offset_right = offset.x + button_size.x
    b.offset_bottom = offset.y + button_size.y
    b.add_theme_font_size_override("font_size", 28)
    b.focus_mode = Control.FOCUS_NONE
    return b

func _left_down() -> void:
    touch_left = true

func _left_up() -> void:
    touch_left = false

func _right_down() -> void:
    touch_right = true

func _right_up() -> void:
    touch_right = false

func _gas_down() -> void:
    touch_gas = true

func _gas_up() -> void:
    touch_gas = false

func _brake_down() -> void:
    touch_brake = true

func _brake_up() -> void:
    touch_brake = false

func _reset_car() -> void:
    car.global_position = Vector3(0, 1.0, 0)
    car.rotation = Vector3.ZERO
    car.velocity = Vector3.ZERO
    speed = 0.0
    steer = 0.0

func _physics_process(delta: float) -> void:
    var throttle := Input.get_axis("ui_down", "ui_up")
    var turn := Input.get_axis("ui_left", "ui_right")

    if touch_gas and not touch_brake:
        throttle = 1.0
    elif touch_brake and not touch_gas:
        throttle = -1.0

    if touch_left and not touch_right:
        turn = -1.0
    elif touch_right and not touch_left:
        turn = 1.0

    var target_speed := throttle * 34.0
    var accel := 22.0 if abs(throttle) > 0.01 else 12.0
    speed = move_toward(speed, target_speed, delta * accel)
    steer = move_toward(steer, turn, delta * 4.0)

    if abs(speed) > 0.1:
        car.rotate_y(-steer * delta * clamp(abs(speed) / 12.0, 0.25, 1.6) * sign(speed))

    var forward := -car.global_transform.basis.z
    car.velocity = Vector3(forward.x * speed, -4.0, forward.z * speed)
    car.move_and_slide()

    if hud_label != null:
        hud_label.text = "YARDMAN • MAP BASELINE\n%.0f km/h  |  road-stream QA\nX %.0f m   Z %.0f m\nJAD2001 / EPSG:3448 • 1 unit = 1 metre" % [
            abs(speed) * 3.6,
            car.global_position.x,
            car.global_position.z,
        ]
