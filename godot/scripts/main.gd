extends Node3D

const PARISHES = [
    ["Kingston", Vector3(0,0,0)],
    ["St. Andrew", Vector3(-4200,0,-6200)],
    ["St. Catherine", Vector3(-21000,0,-1800)],
    ["Clarendon", Vector3(-41000,0,3500)],
    ["Manchester", Vector3(-56000,0,9000)],
    ["St. Elizabeth", Vector3(-76000,0,13000)],
    ["Westmoreland", Vector3(-96000,0,6000)],
    ["Hanover", Vector3(-106000,0,-8000)],
    ["St. James", Vector3(-91000,0,-16500)],
    ["Trelawny", Vector3(-70000,0,-19000)],
    ["St. Ann", Vector3(-47000,0,-21000)],
    ["St. Mary", Vector3(-25000,0,-22500)],
    ["Portland", Vector3(-5000,0,-19000)],
    ["St. Thomas", Vector3(12000,0,-8500)]
]

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
    _make_island_proxy()
    _make_kingston_test_grid()
    _make_parish_markers()
    _make_car()
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

func _make_island_proxy() -> void:
    # Full-island coordinate envelope. One Godot unit equals one real-world metre.
    var ground := MeshInstance3D.new()
    var mesh := PlaneMesh.new()
    mesh.size = Vector2(235000, 82000)
    ground.mesh = mesh
    ground.position = Vector3(-47000, -0.05, -3000)
    var mat := StandardMaterial3D.new()
    mat.albedo_color = Color(0.18, 0.38, 0.16)
    ground.material_override = mat
    add_child(ground)

    var body := StaticBody3D.new()
    var shape := CollisionShape3D.new()
    var box := BoxShape3D.new()
    box.size = Vector3(235000, 1, 82000)
    shape.shape = box
    body.position = Vector3(-47000, -0.55, -3000)
    body.add_child(shape)
    add_child(body)

func _make_kingston_test_grid() -> void:
    # First local fidelity layer: a light Kingston road/building grid while the
    # full Jamaica coordinate space remains active at true horizontal scale.
    var road_mat := StandardMaterial3D.new()
    road_mat.albedo_color = Color(0.12, 0.13, 0.14)
    road_mat.roughness = 0.9

    for z in [-420.0, -140.0, 140.0, 420.0]:
        var road := MeshInstance3D.new()
        var road_mesh := BoxMesh.new()
        road_mesh.size = Vector3(1400.0, 0.04, 18.0)
        road.mesh = road_mesh
        road.position = Vector3(0, 0.03, z)
        road.material_override = road_mat
        add_child(road)

    for x in [-420.0, -140.0, 140.0, 420.0]:
        var road := MeshInstance3D.new()
        var road_mesh := BoxMesh.new()
        road_mesh.size = Vector3(18.0, 0.04, 1100.0)
        road.mesh = road_mesh
        road.position = Vector3(x, 0.03, 0)
        road.material_override = road_mat
        add_child(road)

    var building_mat := StandardMaterial3D.new()
    building_mat.albedo_color = Color(0.62, 0.58, 0.50)
    for i in range(48):
        var gx := float((i % 8) - 4) * 105.0 + 48.0
        var gz := float((i / 8) - 3) * 125.0 + 52.0
        if abs(gx) < 28.0 or abs(gz) < 28.0:
            continue
        var h := 12.0 + float((i * 17) % 45)
        var building := MeshInstance3D.new()
        var bm := BoxMesh.new()
        bm.size = Vector3(42.0 + float(i % 3) * 8.0, h, 52.0)
        building.mesh = bm
        building.position = Vector3(gx, h * 0.5, gz)
        building.material_override = building_mat
        add_child(building)

func _make_parish_markers() -> void:
    for p in PARISHES:
        var marker := MeshInstance3D.new()
        var cyl := CylinderMesh.new()
        cyl.top_radius = 80
        cyl.bottom_radius = 80
        cyl.height = 8
        marker.mesh = cyl
        marker.position = p[1]
        var mat := StandardMaterial3D.new()
        mat.albedo_color = Color(0.9, 0.85, 0.2)
        marker.material_override = mat
        add_child(marker)

func _make_car() -> void:
    car = CharacterBody3D.new()
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
    var shape := BoxShape3D.new()
    shape.size = Vector3(1.9, 0.7, 4.2)
    collider.shape = shape
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
    layer.name = "MobileHUD"
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
    left.button_down.connect(Callable(self, "_left_down"))
    left.button_up.connect(Callable(self, "_left_up"))
    root.add_child(left)

    var right := _touch_button("▶", 0.0, 1.0, Vector2(190, -174), Vector2(150, 150))
    right.button_down.connect(Callable(self, "_right_down"))
    right.button_up.connect(Callable(self, "_right_up"))
    root.add_child(right)

    var brake := _touch_button("BRAKE", 1.0, 1.0, Vector2(-350, -174), Vector2(150, 150))
    brake.button_down.connect(Callable(self, "_brake_down"))
    brake.button_up.connect(Callable(self, "_brake_up"))
    root.add_child(brake)

    var gas := _touch_button("GAS", 1.0, 1.0, Vector2(-174, -174), Vector2(150, 150))
    gas.button_down.connect(Callable(self, "_gas_down"))
    gas.button_up.connect(Callable(self, "_gas_up"))
    root.add_child(gas)

    var reset := _touch_button("RESET", 1.0, 0.0, Vector2(-174, 24), Vector2(150, 72))
    reset.pressed.connect(Callable(self, "_reset_car"))
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

func _nearest_parish_name() -> String:
    var best_name := "Kingston"
    var best_dist := INF
    for p in PARISHES:
        var a := Vector2(car.global_position.x, car.global_position.z)
        var b := Vector2(p[1].x, p[1].z)
        var d := a.distance_squared_to(b)
        if d < best_dist:
            best_dist = d
            best_name = p[0]
    return best_name

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
        hud_label.text = "YARDMAN BETA 0.1\n%.0f km/h  |  %s\nX %.0f m   Z %.0f m\nJamaica: 1 m = 1 world unit | 14 parishes" % [abs(speed) * 3.6, _nearest_parish_name(), car.global_position.x, car.global_position.z]
