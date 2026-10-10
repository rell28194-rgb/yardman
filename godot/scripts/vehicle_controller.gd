extends RefCounted
class_name YardmanVehicleController

const ModelScript = preload("res://scripts/vehicle_model.gd")
const MAX_FORWARD_MPS := 42.0
const MAX_REVERSE_MPS := 7.0
const GRASS_LIMIT_MPS := 18.0
const WHEELBASE_M := 2.56

var body: CharacterBody3D
var speed_mps := 0.0
var odometer_m := 0.0
var occupied := true
var brake_input := 0.0
var handbrake := false
var on_road := true
var engine_rpm := 900.0
var steering_angle := 0.0
var visual: Node3D
var _steer := 0.0
var _ground_basis := Basis.IDENTITY
var _last_acceleration := 0.0
var _last_yaw_rate := 0.0
var _last_throttle := 0.0

func configure(vehicle: CharacterBody3D) -> void:
    body = vehicle
    body.floor_snap_length = 0.7
    body.floor_max_angle = deg_to_rad(52.0)
    body.floor_stop_on_slope = true
    body.floor_constant_speed = true
    # Replace the old blockout here so every caller receives the same model.
    var old_visual := body.get_node_or_null("VisualRig")
    if old_visual != null:
        body.remove_child(old_visual)
        old_visual.queue_free()
    visual = ModelScript.new()
    visual.name = "VisualRig"
    body.add_child(visual)
    visual.call("build")
    _ground_basis = Basis.IDENTITY

func step(delta: float, throttle: float, turn: float, ready: bool) -> void:
    # A parked car outside collision residency must not fall or change pose.
    # Its canonical double-precision position belongs to the world state.
    if body == null or not ready or delta <= 0.0:
        return
    var dt := minf(delta, 0.1)
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
        braking = maxf(braking, 0.85)
    var traction := body.is_on_floor()
    if braking > 0.01:
        var brake_deceleration := (10.8 if on_road else 6.6) * braking
        if not traction:
            brake_deceleration *= 0.1
        speed_mps = move_toward(speed_mps, 0.0, brake_deceleration * dt)
    elif absf(throttle) > 0.02 and traction:
        var limit := MAX_REVERSE_MPS if throttle < 0.0 else (MAX_FORWARD_MPS if on_road else GRASS_LIMIT_MPS)
        var speed_fraction := clampf(absf(speed_mps) / MAX_FORWARD_MPS, 0.0, 1.0)
        # Usable torque from standstill through the gears replaces a desired
        # speed lerp. The service brake is independent of reverse selection.
        var acceleration := (6.7 - 2.2 * speed_fraction) * absf(throttle)
        if throttle < 0.0:
            acceleration *= 0.70
        if not on_road:
            acceleration *= 0.72
        if absf(speed_mps) < limit:
            speed_mps += signf(throttle) * acceleration * dt
            speed_mps = clampf(speed_mps, -MAX_REVERSE_MPS, MAX_FORWARD_MPS)
    var rolling_drag := 0.10 + absf(speed_mps) * absf(speed_mps) * 0.0012
    if not on_road:
        rolling_drag += 0.62 + absf(speed_mps) * absf(speed_mps) * 0.0035
        if speed_mps > GRASS_LIMIT_MPS:
            rolling_drag += 2.0 + (speed_mps - GRASS_LIMIT_MPS) * 0.30
    if traction:
        speed_mps = move_toward(speed_mps, 0.0, rolling_drag * dt)
    if absf(speed_mps) < 0.055 and absf(throttle) < 0.02:
        speed_mps = 0.0
    _steer = move_toward(_steer, turn, dt * 5.8)
    var steering_limit := lerpf(deg_to_rad(34.0), deg_to_rad(10.0), clampf(absf(speed_mps) / MAX_FORWARD_MPS, 0.0, 1.0))
    steering_angle = -_steer * steering_limit
    var yaw_rate := speed_mps * tan(steering_angle) / WHEELBASE_M
    # Tyre grip bounds lateral acceleration at speed. Full-lock input cannot
    # spin a 150 km/h car around its centre as the previous controller did.
    var grip := 8.4 if on_road else 4.8
    if handbrake:
        grip *= 0.68
    var yaw_limit := minf(1.12, grip / maxf(absf(speed_mps), 1.0))
    yaw_rate = clampf(yaw_rate, -yaw_limit, yaw_limit) if traction else 0.0
    body.rotate_y(yaw_rate * dt)
    _last_yaw_rate = yaw_rate
    var forward := -body.global_transform.basis.z
    var desired_horizontal := Vector2(forward.x, forward.z).normalized() * speed_mps
    var horizontal := Vector2(body.velocity.x, body.velocity.z)
    var response := (13.0 if on_road else 7.0) * (0.45 if handbrake else 1.0)
    if traction:
        horizontal = horizontal.lerp(desired_horizontal, 1.0 - exp(-response * dt))
    body.velocity.x = horizontal.x
    body.velocity.z = horizontal.y
    body.velocity.y = -1.2 if traction else body.velocity.y - 23.0 * dt
    var before := body.global_position
    body.move_and_slide()
    odometer_m += Vector2(body.global_position.x - before.x, body.global_position.z - before.z).length()
    if body.is_on_wall():
        speed_mps = Vector2(body.velocity.x, body.velocity.z).dot(Vector2(forward.x, forward.z))
    _last_acceleration = (speed_mps - previous_speed) / dt
    _update_visual(dt, forward, braking)
    var ratios := [400.0, 230.0, 170.0, 135.0, 106.0]
    var ratio: float = ratios[_gear_index()]
    var target_rpm := clampf(950.0 + absf(speed_mps) * ratio + absf(throttle) * 350.0, 850.0, 6500.0) if occupied else 0.0
    engine_rpm = lerpf(engine_rpm, target_rpm, 1.0 - exp(-dt * 8.0))

func _update_visual(delta: float, forward: Vector3, braking: float) -> void:
    if visual == null:
        return
    if body.is_on_floor():
        var up := body.get_floor_normal().normalized()
        var ahead := forward.slide(up).normalized()
        if ahead.length_squared() > 0.01:
            var desired_basis := body.global_basis.inverse() * Basis.looking_at(ahead, up)
            _ground_basis = _ground_basis.slerp(desired_basis, 1.0 - exp(-delta * 7.0)).orthonormalized()
    visual.basis = _ground_basis
    var body_pitch := clampf(_last_acceleration * 0.0038, -0.055, 0.035)
    var body_roll := clampf(-_last_yaw_rate * speed_mps * 0.0060, -0.07, 0.07)
    visual.call("update_motion", delta, speed_mps, steering_angle, braking, speed_mps < -0.15, occupied, body_pitch, body_roll)

func _gear_index() -> int:
    var forward_speed := absf(speed_mps)
    if forward_speed < 8.0:
        return 0
    if forward_speed < 15.0:
        return 1
    if forward_speed < 23.0:
        return 2
    if forward_speed < 32.0:
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
    _last_throttle = 0.0
    _last_acceleration = 0.0
    _last_yaw_rate = 0.0
    engine_rpm = 900.0 if occupied else 0.0
    _ground_basis = Basis.IDENTITY
    if body != null:
        body.velocity = Vector3.ZERO
    if visual != null:
        visual.basis = Basis.IDENTITY
        visual.call("update_motion", 1.0, 0.0, 0.0, 0.0, false, occupied, 0.0, 0.0)
