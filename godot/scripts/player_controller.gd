extends CharacterBody3D
class_name YardmanPlayerController

var in_vehicle := true
var vehicle
var movement := Vector2.ZERO
var camera_yaw := 0.0
var sprinting := false

func _ready() -> void:
    collision_layer = 4
    collision_mask = 3
    floor_snap_length = 0.5
    var shape := CapsuleShape3D.new()
    shape.radius = 0.3
    shape.height = 1.75
    var collider := CollisionShape3D.new()
    collider.name = "PlayerShape"
    collider.shape = shape
    collider.position.y = 0.875
    add_child(collider)
    _make_character()
    _set_occupied(true)

func configure(controller) -> void:
    vehicle = controller

func step(delta: float, ready: bool) -> void:
    if in_vehicle:
        global_position = vehicle.body.global_position
        return
    if not ready:
        return
    var direction := Vector3(movement.x, 0.0, movement.y).rotated(Vector3.UP, camera_yaw)
    if direction.length_squared() > 1.0:
        direction = direction.normalized()
    var speed := 7.5 if sprinting else 4.7
    velocity.x = move_toward(velocity.x, direction.x * speed, delta * 24.0)
    velocity.z = move_toward(velocity.z, direction.z * speed, delta * 24.0)
    velocity.y = -1.0 if is_on_floor() else velocity.y - 22.0 * delta
    move_and_slide()
    if direction.length_squared() > 0.01:
        var rig := get_node("VisualRig") as Node3D
        rig.rotation.y = lerp_angle(rig.rotation.y, atan2(-direction.x, -direction.z), clampf(delta * 12.0, 0.0, 1.0))

func try_enter_vehicle() -> bool:
    if in_vehicle or vehicle == null or global_position.distance_to(vehicle.body.global_position) > 3.7 or absf(vehicle.speed_mps) > 2.0:
        return false
    _set_occupied(true)
    return true

func try_exit_vehicle() -> bool:
    if not in_vehicle or vehicle == null or absf(vehicle.speed_mps) > 2.0:
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
        query.transform = Transform3D(Basis.IDENTITY, candidate + Vector3.UP * 0.875)
        query.collision_mask = 3
        query.exclude = [car.get_rid(), get_rid()]
        if not get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty():
            continue
        global_position = candidate
        velocity = Vector3.ZERO
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

func _part(parent: Node3D, mesh: Mesh, position_local: Vector3, color: Color) -> void:
    var instance := MeshInstance3D.new()
    instance.mesh = mesh
    instance.position = position_local
    var material := StandardMaterial3D.new()
    material.albedo_color = color
    material.roughness = 0.85
    instance.material_override = material
    parent.add_child(instance)

func _make_character() -> void:
    var rig := Node3D.new()
    rig.name = "VisualRig"
    add_child(rig)
    var torso := CapsuleMesh.new()
    torso.radius = 0.25
    torso.height = 0.72
    _part(rig, torso, Vector3(0, 1.14, 0), Color(0.1, 0.42, 0.24))
    var head := SphereMesh.new()
    head.radius = 0.17
    head.height = 0.34
    _part(rig, head, Vector3(0, 1.67, 0), Color(0.30, 0.17, 0.10))
    for side in [-1.0, 1.0]:
        var leg := CapsuleMesh.new()
        leg.radius = 0.10
        leg.height = 0.76
        _part(rig, leg, Vector3(side * 0.13, 0.45, 0), Color(0.12, 0.14, 0.18))
        var arm := CapsuleMesh.new()
        arm.radius = 0.075
        arm.height = 0.62
        _part(rig, arm, Vector3(side * 0.31, 1.10, 0), Color(0.30, 0.17, 0.10))
