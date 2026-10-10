extends CharacterBody3D
class_name YardmanPlayerController

var in_vehicle := true
var vehicle
var movement := Vector2.ZERO
var camera_yaw := 0.0
var sprinting := false
var reduced_motion := false
var walk_speed := 3.8
var sprint_speed := 7.2
var _visual: Node3D
var _left_arm: Node3D
var _right_arm: Node3D
var _left_leg: Node3D
var _right_leg: Node3D
var _gait := 0.0
var _motion_blend := 0.0

func _ready() -> void:
    collision_layer = 4
    collision_mask = 3
    floor_snap_length = 0.6
    floor_max_angle = deg_to_rad(48.0)
    var shape := CapsuleShape3D.new()
    shape.radius = 0.29
    shape.height = 1.76
    var collider := CollisionShape3D.new()
    collider.name = "PlayerShape"
    collider.shape = shape
    collider.position.y = 0.88
    add_child(collider)
    _make_character()
    _set_occupied(true)

func configure(controller) -> void:
    vehicle = controller

func step(delta: float, ready: bool) -> void:
    if in_vehicle:
        global_position = vehicle.body.global_position
        _animate(delta, 0.0)
        return
    if not ready:
        velocity = Vector3.ZERO
        _animate(delta, 0.0)
        return
    var move_input := movement.limit_length(1.0)
    var direction := Vector3(move_input.x, 0.0, move_input.y).rotated(Vector3.UP, camera_yaw)
    var speed := sprint_speed if sprinting else walk_speed
    var acceleration := 16.0 if direction.length_squared() > 0.001 else 23.0
    velocity.x = move_toward(velocity.x, direction.x * speed, delta * acceleration)
    velocity.z = move_toward(velocity.z, direction.z * speed, delta * acceleration)
    velocity.y = -1.5 if is_on_floor() else maxf(velocity.y - 22.0 * delta, -45.0)
    move_and_slide()
    if direction.length_squared() > 0.001:
        _visual.rotation.y = lerp_angle(_visual.rotation.y, atan2(-direction.x, -direction.z), clampf(delta * 11.0, 0.0, 1.0))
    _animate(delta, Vector2(velocity.x, velocity.z).length())

func can_enter_vehicle() -> bool:
    return not in_vehicle and vehicle != null and global_position.distance_to(vehicle.body.global_position) <= 3.7 and absf(vehicle.speed_mps) <= 2.0

func can_exit_vehicle() -> bool:
    return in_vehicle and vehicle != null and absf(vehicle.speed_mps) <= 2.0

func try_enter_vehicle() -> bool:
    if not can_enter_vehicle():
        return false
    _set_occupied(true)
    return true

func try_exit_vehicle() -> bool:
    if not can_exit_vehicle():
        return false
    var car: CharacterBody3D = vehicle.body
    for side in [1.0, -1.0]:
        var candidate: Vector3 = car.global_position + car.global_basis.x * (1.8 * side)
        var ray := PhysicsRayQueryParameters3D.create(candidate + Vector3.UP * 5.0, candidate - Vector3.UP * 8.0, 1)
        ray.exclude = [car.get_rid(), get_rid()]
        var hit := get_world_3d().direct_space_state.intersect_ray(ray)
        if hit.is_empty():
            continue
        candidate.y = float(hit.position.y) + 0.05
        var query := PhysicsShapeQueryParameters3D.new()
        query.shape = (get_node("PlayerShape") as CollisionShape3D).shape
        query.transform = Transform3D(Basis.IDENTITY, candidate + Vector3.UP * 0.88)
        query.collision_mask = 3
        query.exclude = [car.get_rid(), get_rid()]
        if not get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty():
            continue
        global_position = candidate
        velocity = Vector3.ZERO
        _visual.rotation.y = car.rotation.y
        _set_occupied(false)
        return true
    return false

func _set_occupied(value: bool) -> void:
    in_vehicle = value
    if vehicle != null:
        vehicle.occupied = value
    collision_mask = 0 if value else 3
    collision_layer = 0 if value else 4
    visible = not value
    velocity = Vector3.ZERO
    movement = Vector2.ZERO

func _animate(delta: float, horizontal_speed: float) -> void:
    if _visual == null:
        return
    _motion_blend = move_toward(_motion_blend, clampf(horizontal_speed / walk_speed, 0.0, 1.5), delta * 6.0)
    _gait += delta * (6.5 + horizontal_speed * 1.15)
    var swing := sin(_gait) * 0.48 * _motion_blend
    _left_leg.rotation.x = swing
    _right_leg.rotation.x = -swing
    _left_arm.rotation.x = -swing * 0.75
    _right_arm.rotation.x = swing * 0.75
    _visual.position.y = 0.0 if reduced_motion else absf(sin(_gait)) * 0.025 * _motion_blend
    _visual.rotation.x = -0.035 * _motion_blend if sprinting else 0.0

func _part(parent: Node3D, mesh: Mesh, position_local: Vector3, color: Color) -> MeshInstance3D:
    var instance := MeshInstance3D.new()
    instance.mesh = mesh
    instance.position = position_local
    var material := StandardMaterial3D.new()
    material.albedo_color = color
    material.roughness = 0.82
    instance.material_override = material
    parent.add_child(instance)
    return instance

func _capsule(radius: float, height: float) -> CapsuleMesh:
    var mesh := CapsuleMesh.new()
    mesh.radius = radius
    mesh.height = height
    mesh.radial_segments = 12
    mesh.rings = 4
    return mesh

func _limb(parent: Node3D, origin: Vector3, radius: float, length: float, color: Color) -> Node3D:
    var pivot := Node3D.new()
    pivot.position = origin
    parent.add_child(pivot)
    _part(pivot, _capsule(radius, length), Vector3(0.0, -length * 0.45, 0.0), color)
    return pivot

func _make_character() -> void:
    _visual = Node3D.new()
    _visual.name = "VisualRig"
    add_child(_visual)
    var skin := Color(0.34, 0.20, 0.13)
    var shirt := Color(0.14, 0.31, 0.23)
    var trousers := Color(0.12, 0.15, 0.19)
    _part(_visual, _capsule(0.25, 0.67), Vector3(0, 1.15, 0), shirt)
    var head := SphereMesh.new()
    head.radius = 0.17
    head.height = 0.35
    head.radial_segments = 16
    head.rings = 8
    _part(_visual, head, Vector3(0, 1.66, 0), skin)
    var hair := SphereMesh.new()
    hair.radius = 0.174
    hair.height = 0.20
    hair.radial_segments = 12
    hair.rings = 6
    _part(_visual, hair, Vector3(0, 1.77, 0), Color(0.055, 0.038, 0.029))
    var nose := SphereMesh.new()
    nose.radius = 0.038
    nose.height = 0.062
    nose.radial_segments = 8
    nose.rings = 4
    _part(_visual, nose, Vector3(0, 1.64, -0.167), skin)
    _left_leg = _limb(_visual, Vector3(-0.125, 0.86, 0), 0.097, 0.78, trousers)
    _right_leg = _limb(_visual, Vector3(0.125, 0.86, 0), 0.097, 0.78, trousers)
    _left_arm = _limb(_visual, Vector3(-0.315, 1.41, 0), 0.080, 0.64, skin)
    _right_arm = _limb(_visual, Vector3(0.315, 1.41, 0), 0.080, 0.64, skin)
    for leg in [_left_leg, _right_leg]:
        var shoe := BoxMesh.new()
        shoe.size = Vector3(0.21, 0.12, 0.32)
        _part(leg, shoe, Vector3(0, -0.76, -0.06), Color(0.08, 0.075, 0.064))
    for side in [-1.0, 1.0]:
        var eye := SphereMesh.new()
        eye.radius = 0.016
        eye.height = 0.025
        eye.radial_segments = 6
        eye.rings = 3
        _part(_visual, eye, Vector3(side * 0.058, 1.69, -0.155), Color(0.04, 0.025, 0.02))
