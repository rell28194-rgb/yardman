extends RefCounted
class_name YardmanVehicleController

const ModelScript = preload("res://scripts/vehicle_model.gd")
const MAX_FORWARD_MPS := 58.0
const MAX_REVERSE_MPS := 7.0
const GRASS_LIMIT_MPS := 17.0
const WHEELBASE_M := 2.56
const DRIFT_LATERAL_CAP_MPS := 9.5
const SUSPENSION_RAY_TOP_M := 0.95
const SUSPENSION_RAY_LENGTH_M := 1.65

var body: CharacterBody3D
var speed_mps := 0.0
var odometer_m := 0.0
var occupied := true
var brake_input := 0.0
var handbrake := false
var drift_assist := false
var drift_angle_deg := 0.0
var drifting := false
var on_road := true
var engine_rpm := 900.0
var steering_angle := 0.0
var wheelbase_m := WHEELBASE_M
var visual: Node3D
var _steer := 0.0
var _ground_basis := Basis.IDENTITY
var _last_acceleration := 0.0
var _last_yaw_rate := 0.0
var _last_throttle := 0.0
var _lateral_speed := 0.0
var _probe_normal := Vector3.UP
var _contact_ratio := 1.0
var _suspension_compression := 0.35
var _track_half_m := 0.72
var _headlights: Array[SpotLight3D] = []

func configure(vehicle: CharacterBody3D) -> void:
    body = vehicle
    body.floor_snap_length = 0.42
    body.floor_max_angle = deg_to_rad(45.0)
    body.floor_stop_on_slope = false
    body.floor_constant_speed = false
    var old_visual := body.get_node_or_null("VisualRig")
    if old_visual != null:
        body.remove_child(old_visual)
        old_visual.queue_free()
    visual = ModelScript.new()
    visual.name = "VisualRig"
    body.add_child(visual)
    visual.call("build")
    wheelbase_m = clampf(float(visual.get("wheelbase_m")), 1.8, 4.5)
    var bounds: AABB = visual.get("geometry_bounds")
    _track_half_m = clampf(bounds.size.x * 0.36, 0.58, 0.92)
    if bool(visual.get("is_reference_model")):
        _fit_reference_collision()
    _make_headlights(bounds)
    _ground_basis = Basis.IDENTITY

func _make_headlights(bounds: AABB) -> void:
    _headlights.clear()
    var half_width := bounds.size.x * 0.5
    var lamp_x := clampf(half_width * 0.62, 0.48, 0.72)
    var lamp_y := clampf(bounds.position.y + bounds.size.y * 0.43, 0.55, 0.92)
    var front_z := bounds.position.z - 0.06
    for x in [-lamp_x, lamp_x]:
        var light := SpotLight3D.new()
        light.name = "HeadlightLeft" if x < 0.0 else "HeadlightRight"
        light.position = Vector3(x, lamp_y, front_z)
        light.light_color = Color(1.0, 0.91, 0.75)
        light.light_energy = 4.2
        light.spot_range = 46.0
        light.spot_angle = 31.0
        light.spot_angle_attenuation = 1.35
        light.shadow_enabled = false
        light.distance_fade_enabled = true
        light.distance_fade_begin = 28.0
        light.distance_fade_length = 22.0
        visual.add_child(light)
        _headlights.append(light)

func _fit_reference_collision() -> void:
    var bounds: AABB = visual.get("geometry_bounds")
    for node in body.find_children("*", "CollisionShape3D", true, false):
        var collision := node as CollisionShape3D
        if collision == null or not collision.shape is BoxShape3D:
            continue
        var shape := collision.shape.duplicate() as BoxShape3D
        shape.size = Vector3(bounds.size.x * 0.94, maxf(bounds.size.y * 0.76, 0.92), bounds.size.z * 0.91)
        collision.shape = shape
        var centre := bounds.get_center()
        collision.position = Vector3(centre.x, maxf(shape.size.y * 0.48, 0.46), centre.z)
        break

func _sample_ground_contacts() -> void:
    if body == null or not body.is_inside_tree() or body.get_world_3d() == null:
        _probe_normal = Vector3.UP
        _contact_ratio = 0.0
        return
    var space := body.get_world_3d().direct_space_state
    var axle_z := wheelbase_m * 0.50
    var points: Array[Vector3] = [
        Vector3(-_track_half_m, SUSPENSION_RAY_TOP_M, -axle_z),
        Vector3(_track_half_m, SUSPENSION_RAY_TOP_M, -axle_z),
        Vector3(-_track_half_m, SUSPENSION_RAY_TOP_M, axle_z),
        Vector3(_track_half_m, SUSPENSION_RAY_TOP_M, axle_z),
    ]
    var normal_sum := Vector3.ZERO
    var compression_sum := 0.0
    var contacts := 0
    for point in points:
        var start: Vector3 = body.global_transform * point
        var finish: Vector3 = start - Vector3.UP * SUSPENSION_RAY_LENGTH_M
        var query := PhysicsRayQueryParameters3D.create(start, finish, 1)
        query.exclude = [body.get_rid()]
        query.collide_with_areas = false
        var hit: Dictionary = space.intersect_ray(query)
        if hit.is_empty():
            continue
        contacts += 1
        var normal: Vector3 = hit["normal"]
        normal_sum += normal.normalized()
        var hit_position: Vector3 = hit["position"]
        var distance: float = start.distance_to(hit_position)
        compression_sum += clampf((SUSPENSION_RAY_LENGTH_M - distance) / 0.72, 0.0, 1.0)
    _contact_ratio = float(contacts) / 4.0
    if contacts > 0:
        _probe_normal = (normal_sum / float(contacts)).normalized()
        _suspension_compression = lerpf(_suspension_compression, compression_sum / float(contacts), 0.32)
    else:
        _probe_normal = Vector3.UP
        _suspension_compression = lerpf(_suspension_compression, 0.0, 0.20)

func step(delta: float, throttle: float, turn: float, ready: bool) -> void:
    if body == null or not ready or delta <= 0.0:
        return
    var dt := minf(delta, 0.1)
    _sample_ground_contacts()
    throttle = clampf(throttle, -1.0, 1.0) if occupied else 0.0
    turn = clampf(turn, -1.0, 1.0) if occupied else 0.0
    _last_throttle = throttle
    var previous_speed := speed_mps
    var braking := clampf(brake_input, 0.0, 1.0)
    var reverse_braking := (throttle < -0.02 and speed_mps > 0.18) or (throttle > 0.02 and speed_mps < -0.18)
    if reverse_braking:
        braking = maxf(braking, absf(throttle))
    if not occupied:
        braking = 1.0
    if handbrake:
        braking = maxf(braking, 0.42)
    var traction := body.is_on_floor() or _contact_ratio >= 0.50
    if braking > 0.01:
        var brake_deceleration := (12.0 if on_road else 7.2) * braking
        if handbrake and absf(turn) > 0.10 and absf(speed_mps) > 7.0:
            brake_deceleration *= 0.52
        if not traction:
            brake_deceleration *= 0.1
        speed_mps = move_toward(speed_mps, 0.0, brake_deceleration * dt)
    elif absf(throttle) > 0.02 and traction:
        var limit := MAX_REVERSE_MPS if throttle < 0.0 else (MAX_FORWARD_MPS if on_road else GRASS_LIMIT_MPS)
        var speed_fraction := clampf(absf(speed_mps) / MAX_FORWARD_MPS, 0.0, 1.0)
        var acceleration := (7.6 - 3.0 * speed_fraction) * absf(throttle)
        if throttle < 0.0:
            acceleration *= 0.67
        if not on_road:
            acceleration *= 0.70
        if absf(speed_mps) < limit:
            speed_mps += signf(throttle) * acceleration * dt
            speed_mps = clampf(speed_mps, -MAX_REVERSE_MPS, MAX_FORWARD_MPS)
    var rolling_drag := 0.085 + absf(speed_mps) * absf(speed_mps) * 0.00072
    if not on_road:
        rolling_drag += 0.68 + absf(speed_mps) * absf(speed_mps) * 0.0037
        if speed_mps > GRASS_LIMIT_MPS:
            rolling_drag += 2.2 + (speed_mps - GRASS_LIMIT_MPS) * 0.32
    if traction:
        speed_mps = move_toward(speed_mps, 0.0, rolling_drag * dt)
    if absf(speed_mps) < 0.055 and absf(throttle) < 0.02:
        speed_mps = 0.0
    _steer = move_toward(_steer, turn, dt * 6.5)
    var speed_fraction := clampf(absf(speed_mps) / MAX_FORWARD_MPS, 0.0, 1.0)
    var steering_limit := lerpf(deg_to_rad(36.0), deg_to_rad(13.0), pow(speed_fraction, 0.72))
    steering_angle = -_steer * steering_limit
    var yaw_rate := speed_mps * tan(steering_angle) / wheelbase_m
    var drift_mode := on_road and traction and absf(speed_mps) > 7.0 and absf(_steer) > 0.12 and (handbrake or drift_assist)
    var grip_accel := 11.5 if on_road else 6.2
    if drift_mode:
        grip_accel = 10.5 if drift_assist else 9.2
    elif handbrake:
        grip_accel *= 0.62
    var yaw_cap := 1.55 if drift_mode else 1.40
    var yaw_limit := minf(yaw_cap, grip_accel / maxf(absf(speed_mps), 1.0))
    yaw_rate = clampf(yaw_rate, -yaw_limit, yaw_limit) if traction else 0.0
    body.rotate_y(yaw_rate * dt)
    _last_yaw_rate = yaw_rate
    var forward := -body.global_transform.basis.z
    var forward_2d := Vector2(forward.x, forward.z).normalized()
    var right_2d := Vector2(-forward_2d.y, forward_2d.x)
    var horizontal := Vector2(body.velocity.x, body.velocity.z)
    if traction:
        var longitudinal := horizontal.dot(forward_2d)
        var lateral := horizontal.dot(right_2d)
        var longitudinal_response := 15.0 if on_road else 7.0
        longitudinal = lerpf(longitudinal, speed_mps, 1.0 - exp(-longitudinal_response * dt))
        if drift_mode:
            var slip_fraction := 0.38 if drift_assist else 0.30
            var slip_bonus := 2.2 if drift_assist else 0.9
            var lateral_target := -_steer * minf(absf(speed_mps) * slip_fraction + slip_bonus, DRIFT_LATERAL_CAP_MPS)
            var slip_response := 3.7 if drift_assist else 2.6
            lateral = lerpf(lateral, lateral_target, 1.0 - exp(-slip_response * dt))
            lateral = clampf(lateral, -DRIFT_LATERAL_CAP_MPS, DRIFT_LATERAL_CAP_MPS)
        else:
            var lateral_response := 7.2 if on_road else 4.8
            lateral = lerpf(lateral, 0.0, 1.0 - exp(-lateral_response * dt))
        _lateral_speed = lateral
        drift_angle_deg = rad_to_deg(atan2(absf(lateral), maxf(absf(longitudinal), 0.1)))
        drifting = drift_mode and drift_angle_deg >= 4.0
        horizontal = forward_2d * longitudinal + right_2d * lateral
    else:
        drift_angle_deg = 0.0
        drifting = false
        _lateral_speed = 0.0
    body.velocity.x = horizontal.x
    body.velocity.z = horizontal.y
    body.velocity.y = -0.65 if body.is_on_floor() else body.velocity.y - 20.5 * dt
    var before := body.global_position
    body.move_and_slide()
    odometer_m += Vector2(body.global_position.x - before.x, body.global_position.z - before.z).length()
    if body.is_on_wall():
        speed_mps = Vector2(body.velocity.x, body.velocity.z).dot(Vector2(forward.x, forward.z))
    _last_acceleration = (speed_mps - previous_speed) / dt
    _update_visual(dt, forward, braking)
    var ratios := [405.0, 245.0, 178.0, 132.0, 101.0]
    var ratio: float = ratios[_gear_index()]
    var target_rpm := clampf(900.0 + absf(speed_mps) * ratio + absf(throttle) * 520.0, 820.0, 6900.0) if occupied else 0.0
    engine_rpm = lerpf(engine_rpm, target_rpm, 1.0 - exp(-dt * 9.0))

func _update_visual(delta: float, forward: Vector3, braking: float) -> void:
    if visual == null:
        return
    var up := _probe_normal if _contact_ratio >= 0.25 else (body.get_floor_normal().normalized() if body.is_on_floor() else Vector3.UP)
    var ahead := forward.slide(up).normalized()
    if ahead.length_squared() > 0.01:
        var desired_basis := body.global_basis.inverse() * Basis.looking_at(ahead, up)
        _ground_basis = _ground_basis.slerp(desired_basis, 1.0 - exp(-delta * 8.5)).orthonormalized()
    visual.basis = _ground_basis
    var suspension_y := lerpf(0.055, -0.035, _suspension_compression)
    visual.position.y = lerpf(visual.position.y, suspension_y, 1.0 - exp(-delta * 10.0))
    for light in _headlights:
        light.visible = occupied
        light.light_energy = lerpf(light.light_energy, 4.2 if occupied else 0.0, 1.0 - exp(-delta * 8.0))
    var body_pitch := clampf(_last_acceleration * 0.0048, -0.070, 0.046)
    var body_roll := clampf(-_last_yaw_rate * speed_mps * 0.0068, -0.09, 0.09)
    if drifting:
        body_roll = clampf(body_roll - signf(_lateral_speed) * 0.022, -0.11, 0.11)
    visual.call("update_motion", delta, speed_mps, steering_angle, braking, speed_mps < -0.15, occupied, body_pitch, body_roll)

func _gear_index() -> int:
    var forward_speed := absf(speed_mps)
    if forward_speed < 9.0:
        return 0
    if forward_speed < 18.0:
        return 1
    if forward_speed < 29.0:
        return 2
    if forward_speed < 42.0:
        return 3
    return 4

func gear_label() -> String:
    if not occupied and absf(speed_mps) < 0.2:
        return "P"
    if speed_mps < -0.15:
        return "R"
    if absf(speed_mps) < 0.05 and absf(_last_throttle) < 0.02:
        return "N"
    return "D%d" % (_gear_index() + 1)

func reset_motion() -> void:
    speed_mps = 0.0
    _steer = 0.0
    steering_angle = 0.0
    brake_input = 0.0
    handbrake = false
    drift_assist = false
    drift_angle_deg = 0.0
    drifting = false
    _lateral_speed = 0.0
    _last_throttle = 0.0
    _last_acceleration = 0.0
    _last_yaw_rate = 0.0
    _probe_normal = Vector3.UP
    _contact_ratio = 1.0
    _suspension_compression = 0.35
    engine_rpm = 900.0 if occupied else 0.0
    _ground_basis = Basis.IDENTITY
    if body != null:
        body.velocity = Vector3.ZERO
    if visual != null:
        visual.basis = Basis.IDENTITY
        visual.position.y = 0.0
        visual.call("update_motion", 1.0, 0.0, 0.0, 0.0, false, occupied, 0.0, 0.0)