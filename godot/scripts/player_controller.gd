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
var jump_speed := 6.6
var gravity := 22.0
var locomotion_state := "vehicle"
var _visual: Node3D
var _left_arm: Node3D
var _right_arm: Node3D
var _left_leg: Node3D
var _right_leg: Node3D
var _left_foot_probe: RayCast3D
var _right_foot_probe: RayCast3D
var _left_leg_rest := Vector3.ZERO
var _right_leg_rest := Vector3.ZERO
var _gait := 0.0
var _motion_blend := 0.0
var _ground_normal := Vector3.UP
var _air_time := 0.0
var _jump_buffer := 0.0
var _coyote_time := 0.0
var _touch_bound := false

const VEHICLE_INTERACTION_SPEED_LIMIT_MPS := 2.0
const ENTER_DOOR_REACH_M := 2.25
const EXIT_SIDE_CLEARANCE_M := 0.76
const EXIT_GROUND_RAY_UP_M := 2.4
const EXIT_GROUND_RAY_DOWN_M := 3.8

func _ready() -> void:
    collision_layer = 4
    collision_mask = 3
    floor_snap_length = 0.6
    floor_max_angle = deg_to_rad(48.0)
    floor_stop_on_slope = true
    floor_block_on_wall = true
    safe_margin = 0.04
    var shape := CapsuleShape3D.new()
    shape.radius = 0.29
    shape.height = 1.76
    var collider := CollisionShape3D.new()
    collider.name = "PlayerShape"
    collider.shape = shape
    collider.position.y = 0.88
    add_child(collider)
    _make_character()
    _make_foot_probes()
    _set_occupied(true)
    call_deferred("_bind_touch_controls")

func configure(controller) -> void:
    vehicle = controller

func _bind_touch_controls() -> void:
    if _touch_bound or not is_inside_tree():
        return
    var scene := get_tree().current_scene
    var touch := scene.find_child("TouchControls", true, false) if scene != null else null
    if touch == null:
        await get_tree().process_frame
        call_deferred("_bind_touch_controls")
        return
    if touch.has_signal("jump_requested") and not touch.jump_requested.is_connected(request_jump):
        touch.jump_requested.connect(request_jump)
    _touch_bound = true

func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_SPACE and not in_vehicle:
        request_jump()
        get_viewport().set_input_as_handled()

func request_jump() -> void:
    if in_vehicle:
        return
    _jump_buffer = 0.14

func step(delta: float, ready: bool) -> void:
    if in_vehicle:
        if vehicle != null:
            global_position = vehicle.body.global_position
        locomotion_state = "vehicle"
        _air_time = 0.0
        _jump_buffer = 0.0
        _coyote_time = 0.0
        _ground_normal = Vector3.UP
        _animate(delta, 0.0)
        return
    if not ready:
        velocity = Vector3.ZERO
        locomotion_state = "idle"
        _jump_buffer = maxf(0.0, _jump_buffer - delta)
        _animate(delta, 0.0)
        return

    _jump_buffer = maxf(0.0, _jump_buffer - delta)
    var grounded_before := is_on_floor()
    if grounded_before:
        _coyote_time = 0.12
    else:
        _coyote_time = maxf(0.0, _coyote_time - delta)

    var move_input := movement.limit_length(1.0)
    var direction := Vector3(move_input.x, 0.0, move_input.y).rotated(Vector3.UP, camera_yaw)
    var speed := sprint_speed if sprinting else walk_speed
    var acceleration := 16.0 if direction.length_squared() > 0.001 else 23.0
    velocity.x = move_toward(velocity.x, direction.x * speed, delta * acceleration)
    velocity.z = move_toward(velocity.z, direction.z * speed, delta * acceleration)

    if _jump_buffer > 0.0 and _coyote_time > 0.0:
        velocity.y = jump_speed
        _jump_buffer = 0.0
        _coyote_time = 0.0
    elif grounded_before:
        velocity.y = -1.5
    else:
        velocity.y = maxf(velocity.y - gravity * delta, -45.0)

    move_and_slide()
    var grounded_after := is_on_floor()
    if grounded_after:
        _air_time = 0.0
        var floor_normal := get_floor_normal()
        if floor_normal.length_squared() > 0.5:
            _ground_normal = _ground_normal.slerp(floor_normal.normalized(), clampf(delta * 10.0, 0.0, 1.0))
    else:
        _air_time += delta
        _ground_normal = _ground_normal.slerp(Vector3.UP, clampf(delta * 4.0, 0.0, 1.0))

    if direction.length_squared() > 0.001:
        _visual.global_rotation.y = lerp_angle(_visual.global_rotation.y, atan2(-direction.x, -direction.z), clampf(delta * 11.0, 0.0, 1.0))
    var horizontal_speed := Vector2(velocity.x, velocity.z).length()
    locomotion_state = locomotion_state_for(false, grounded_after, horizontal_speed, sprinting, walk_speed)
    _animate(delta, horizontal_speed)

func can_enter_vehicle() -> bool:
    if in_vehicle or vehicle == null or vehicle.body == null:
        return false
    if absf(float(vehicle.speed_mps)) > VEHICLE_INTERACTION_SPEED_LIMIT_MPS:
        return false
    return nearest_door_distance(global_position, vehicle.body.global_transform, _vehicle_dimensions()) <= ENTER_DOOR_REACH_M

func can_exit_vehicle() -> bool:
    return in_vehicle and vehicle != null and vehicle.body != null and absf(float(vehicle.speed_mps)) <= VEHICLE_INTERACTION_SPEED_LIMIT_MPS

func try_enter_vehicle() -> bool:
    if not can_enter_vehicle():
        return false
    _set_occupied(true)
    return true

func try_exit_vehicle() -> bool:
    if not can_exit_vehicle() or get_world_3d() == null:
        return false
    var car: CharacterBody3D = vehicle.body
    var space := get_world_3d().direct_space_state
    var collider := get_node_or_null("PlayerShape") as CollisionShape3D
    if collider == null or collider.shape == null:
        return false
    for local_candidate in exit_candidates_local(_vehicle_dimensions(), EXIT_SIDE_CLEARANCE_M):
        var candidate: Vector3 = car.global_transform * local_candidate
        var ray := PhysicsRayQueryParameters3D.create(
            candidate + Vector3.UP * EXIT_GROUND_RAY_UP_M,
            candidate - Vector3.UP * EXIT_GROUND_RAY_DOWN_M,
            1)
        ray.exclude = [car.get_rid(), get_rid()]
        var hit := space.intersect_ray(ray)
        if hit.is_empty():
            continue
        var normal: Vector3 = hit.get("normal", Vector3.UP)
        if not walkable_exit_normal(normal, floor_max_angle):
            continue
        candidate.y = float(hit.position.y) + 0.05

        # Refuse exits that would teleport the player through the vehicle or a
        # nearby wall even when the final capsule itself happens to be clear.
        var door_local := _nearest_door_local(local_candidate, _vehicle_dimensions())
        var door_world: Vector3 = car.global_transform * door_local
        var path := PhysicsRayQueryParameters3D.create(
            door_world + Vector3.UP * 0.78,
            candidate + Vector3.UP * 0.78,
            3)
        path.exclude = [car.get_rid(), get_rid()]
        if not space.intersect_ray(path).is_empty():
            continue

        var query := PhysicsShapeQueryParameters3D.new()
        query.shape = collider.shape
        query.transform = Transform3D(Basis.IDENTITY, candidate + Vector3.UP * 0.88)
        query.collision_mask = 3
        query.exclude = [car.get_rid(), get_rid()]
        if not space.intersect_shape(query, 1).is_empty():
            continue
        global_position = candidate
        velocity = Vector3.ZERO
        _visual.global_rotation.y = car.global_rotation.y
        _set_occupied(false)
        return true
    return false

func _vehicle_dimensions() -> Vector3:
    if vehicle == null:
        return Vector3(1.85, 1.30, 4.0)
    var metadata: Dictionary = vehicle.profile_metadata() if vehicle.has_method("profile_metadata") else {}
    return dimensions_from_profile(metadata)

static func dimensions_from_profile(profile_data: Dictionary) -> Vector3:
    var dimensions: Array = profile_data.get("dimensions_m", [1.85, 1.30, 4.0])
    if dimensions.size() < 3:
        return Vector3(1.85, 1.30, 4.0)
    return Vector3(
        clampf(float(dimensions[0]), 1.20, 3.20),
        clampf(float(dimensions[1]), 0.85, 3.40),
        clampf(float(dimensions[2]), 2.40, 8.50))

static func door_points_local(dimensions: Vector3) -> Array[Vector3]:
    var half_width := dimensions.x * 0.5
    var front_door_z := -dimensions.z * 0.13
    var rear_door_z := dimensions.z * 0.18
    return [
        Vector3(-half_width, 0.72, front_door_z),
        Vector3(half_width, 0.72, front_door_z),
        Vector3(-half_width, 0.72, rear_door_z),
        Vector3(half_width, 0.72, rear_door_z),
    ]

static func exit_candidates_local(dimensions: Vector3, side_clearance: float = EXIT_SIDE_CLEARANCE_M) -> Array[Vector3]:
    var x := dimensions.x * 0.5 + maxf(side_clearance, 0.45)
    var front_z := -dimensions.z * 0.13
    var rear_z := dimensions.z * 0.18
    var forward_escape_z := -dimensions.z * 0.36
    var rear_escape_z := dimensions.z * 0.38
    return [
        Vector3(-x, 0.05, front_z), Vector3(x, 0.05, front_z),
        Vector3(-x, 0.05, rear_z), Vector3(x, 0.05, rear_z),
        Vector3(-x, 0.05, forward_escape_z), Vector3(x, 0.05, forward_escape_z),
        Vector3(-x, 0.05, rear_escape_z), Vector3(x, 0.05, rear_escape_z),
    ]

static func nearest_door_distance(point_world: Vector3, car_transform: Transform3D, dimensions: Vector3) -> float:
    var best := INF
    for local_point in door_points_local(dimensions):
        best = minf(best, point_world.distance_to(car_transform * local_point))
    return best

static func walkable_exit_normal(normal: Vector3, max_floor_angle: float) -> bool:
    if normal.length_squared() < 0.25:
        return false
    return normal.normalized().angle_to(Vector3.UP) <= max_floor_angle + 0.001

static func _nearest_door_local(candidate_local: Vector3, dimensions: Vector3) -> Vector3:
    var best := Vector3.ZERO
    var best_distance := INF
    for door in door_points_local(dimensions):
        var distance := Vector2(candidate_local.x - door.x, candidate_local.z - door.z).length_squared()
        if distance < best_distance:
            best_distance = distance
            best = door
    return best

func _set_occupied(value: bool) -> void:
    in_vehicle = value
    if vehicle != null:
        vehicle.occupied = value
    collision_mask = 0 if value else 3
    collision_layer = 0 if value else 4
    visible = not value
    velocity = Vector3.ZERO
    movement = Vector2.ZERO
    _jump_buffer = 0.0
    _coyote_time = 0.0
    _air_time = 0.0
    locomotion_state = "vehicle" if value else "idle"
    if _left_foot_probe != null:
        _left_foot_probe.enabled = not value
    if _right_foot_probe != null:
        _right_foot_probe.enabled = not value

func _make_foot_probes() -> void:
    _left_foot_probe = _foot_probe("LeftFootProbe", -0.14)
    _right_foot_probe = _foot_probe("RightFootProbe", 0.14)

func _foot_probe(probe_name: String, x_offset: float) -> RayCast3D:
    var probe := RayCast3D.new()
    probe.name = probe_name
    probe.position = Vector3(x_offset, 0.52, 0.0)
    probe.target_position = Vector3(0.0, -0.86, 0.0)
    probe.collision_mask = 1
    probe.exclude_parent = true
    probe.enabled = false
    add_child(probe)
    return probe

func _animate(delta: float, horizontal_speed: float) -> void:
    if _visual == null:
        return
    var airborne := locomotion_state == "airborne"
    var target_blend := clampf(horizontal_speed / walk_speed, 0.0, 1.5)
    if airborne:
        target_blend *= 0.35
    _motion_blend = move_toward(_motion_blend, target_blend, delta * 6.0)
    _gait += delta * (6.5 + horizontal_speed * 1.15)
    var swing := sin(_gait) * 0.48 * _motion_blend
    _left_leg.rotation.x = swing
    _right_leg.rotation.x = -swing
    _left_arm.rotation.x = -swing * 0.75
    _right_arm.rotation.x = swing * 0.75

    var left_y := _left_leg_rest.y
    var right_y := _right_leg_rest.y
    if not airborne and is_inside_tree():
        left_y = _foot_target_y(_left_foot_probe, _left_leg_rest.y)
        right_y = _foot_target_y(_right_foot_probe, _right_leg_rest.y)
    _left_leg.position.y = lerpf(_left_leg.position.y, left_y, clampf(delta * 13.0, 0.0, 1.0))
    _right_leg.position.y = lerpf(_right_leg.position.y, right_y, clampf(delta * 13.0, 0.0, 1.0))

    _visual.position.y = 0.0 if reduced_motion or airborne else absf(sin(_gait)) * 0.025 * _motion_blend
    var slope_tilt := slope_tilt_for(_ground_normal)
    var sprint_lean := -0.035 * _motion_blend if locomotion_state == "sprint" else 0.0
    _visual.rotation.x = lerpf(_visual.rotation.x, slope_tilt.x + sprint_lean, clampf(delta * 8.0, 0.0, 1.0))
    _visual.rotation.z = lerpf(_visual.rotation.z, slope_tilt.y, clampf(delta * 8.0, 0.0, 1.0))

func _foot_target_y(probe: RayCast3D, rest_y: float) -> float:
    if probe == null or not probe.enabled:
        return rest_y
    probe.force_raycast_update()
    if not probe.is_colliding():
        return rest_y
    var hit_local := to_local(probe.get_collision_point())
    return rest_y + clampf(hit_local.y - 0.06, -0.10, 0.14)

static func locomotion_state_for(occupied: bool, grounded: bool, horizontal_speed: float, wants_sprint: bool, walk_speed_value: float = 3.8) -> String:
    if occupied:
        return "vehicle"
    if not grounded:
        return "airborne"
    if horizontal_speed < 0.15:
        return "idle"
    if wants_sprint and horizontal_speed > walk_speed_value * 1.05:
        return "sprint"
    return "walk"

static func slope_tilt_for(normal: Vector3) -> Vector2:
    var safe := normal.normalized() if normal.length_squared() > 0.001 else Vector3.UP
    var denominator := maxf(safe.y, 0.001)
    var pitch := clampf(atan2(safe.z, denominator) * 0.35, -0.14, 0.14)
    var roll := clampf(-atan2(safe.x, denominator) * 0.35, -0.14, 0.14)
    return Vector2(pitch, roll)

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
    _left_leg_rest = _left_leg.position
    _right_leg_rest = _right_leg.position
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
