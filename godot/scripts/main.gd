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
var speed := 0.0
var steer := 0.0

func _ready() -> void:
    _make_environment()
    _make_island_proxy()
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
    env.ambient_light_color = Color(0.8,0.85,0.9)
    env.ambient_light_energy = 0.7
    world_env.environment = env
    add_child(world_env)
    var sun := DirectionalLight3D.new()
    sun.rotation_degrees = Vector3(-55,-35,0)
    sun.light_energy = 1.4
    add_child(sun)

func _make_island_proxy() -> void:
    var ground := MeshInstance3D.new()
    var mesh := PlaneMesh.new()
    mesh.size = Vector2(235000, 82000)
    ground.mesh = mesh
    ground.position = Vector3(-47000,-0.05,-3000)
    var mat := StandardMaterial3D.new()
    mat.albedo_color = Color(0.18,0.38,0.16)
    ground.material_override = mat
    add_child(ground)
    var body := StaticBody3D.new()
    var shape := CollisionShape3D.new()
    var box := BoxShape3D.new()
    box.size = Vector3(235000,1,82000)
    shape.shape = box
    body.position = Vector3(-47000,-0.55,-3000)
    body.add_child(shape)
    add_child(body)

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
        mat.albedo_color = Color(0.9,0.85,0.2)
        marker.material_override = mat
        add_child(marker)

func _make_car() -> void:
    car = CharacterBody3D.new()
    car.position = Vector3(0,1,0)
    var body_mesh := MeshInstance3D.new()
    var box := BoxMesh.new()
    box.size = Vector3(1.9,0.7,4.2)
    body_mesh.mesh = box
    body_mesh.position.y = 0.55
    var mat := StandardMaterial3D.new()
    mat.albedo_color = Color(0.05,0.08,0.12)
    body_mesh.material_override = mat
    car.add_child(body_mesh)
    var collider := CollisionShape3D.new()
    var shape := BoxShape3D.new()
    shape.size = Vector3(1.9,0.7,4.2)
    collider.shape = shape
    collider.position.y = 0.55
    car.add_child(collider)
    add_child(car)

func _make_camera() -> void:
    var cam := Camera3D.new()
    cam.name = "ChaseCamera"
    cam.position = Vector3(0,4.3,8.5)
    cam.rotation_degrees.x = -15
    car.add_child(cam)

func _make_hud() -> void:
    var layer := CanvasLayer.new()
    var label := Label.new()
    label.name = "HUD"
    label.position = Vector2(18,18)
    label.text = "YARDMAN BETA\n1 m = 1 world unit\nAll 14 parishes active\nWASD / arrows or touch mapping next"
    label.add_theme_font_size_override("font_size", 26)
    layer.add_child(label)
    add_child(layer)

func _physics_process(delta: float) -> void:
    var throttle := Input.get_axis("ui_down", "ui_up")
    var turn := Input.get_axis("ui_left", "ui_right")
    speed = move_toward(speed, throttle * 34.0, delta * (22.0 if abs(throttle) > 0.01 else 12.0))
    steer = move_toward(steer, turn, delta * 4.0)
    if abs(speed) > 0.1:
        car.rotate_y(-steer * delta * clamp(abs(speed)/12.0,0.25,1.6) * sign(speed))
    var forward := -car.global_transform.basis.z
    car.velocity = Vector3(forward.x * speed, -1.0, forward.z * speed)
    car.move_and_slide()
