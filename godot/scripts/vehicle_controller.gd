extends RefCounted
class_name YardmanVehicleController

const ModelScript = preload("res://scripts/vehicle_model.gd")
const PROFILE_CROWN_STAGE3 := "crown_stage3_compound_hybrid"
const MAX_FORWARD_MPS := 105.0
const MAX_REVERSE_MPS := 12.0
const GRASS_LIMIT_MPS := 18.0
const WHEELBASE_M := 2.56
const FRONT_ELECTRIC_CUTOFF_MPS := 52.0
const DOWNFORCE_COEFFICIENT := 0.0032
const MAX_DOWNFORCE_ACCEL := 28.0
const STEERING_LOW_SPEED_DEG := 34.0
const STEERING_HIGH_SPEED_DEG := 6.5
const STEERING_FULL_REDUCTION_MPS := 72.0
const STEERING_INPUT_EXPONENT := 1.45

var body: CharacterBody3D
var speed_mps := 0.0
var odometer_m := 0.0
var occupied := true
var brake_input := 0.0
var handbrake := false
var on_road := true
var engine_rpm := 900.0
var steering_angle := 0.0
var wheelbase_m := WHEELBASE_M
var visual: Node3D
var performance_profile := PROFILE_CROWN_STAGE3
var front_electric_assist := 0.0
var compound_boost := 0.0
var downforce_accel := 0.0
var _steer := 0.0
var _yaw_rate_state := 0.0
var _ground_basis := Basis.IDENTITY
var _last_acceleration := 0.0
var _last_yaw_rate := 0.0
var _last_throttle := 0.0

func configure(vehicle: CharacterBody3D) -> void:
    body = vehicle
    body.floor_snap_length = 0.9
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
    wheelbase_m = clampf(float(visual.get("wheelbase_m")), 1.8, 4.5)
    if bool(visual.get("is_reference_model")):
        _fit_reference_collision()
    _ground_basis = Basis.IDENTITY

func _fit_reference_collision() -> void:
    var bounds: AABB = visual.get("geometry_bounds")
    for node in body.find_children("*", "CollisionShape3D", true, false):
        var collision := node as CollisionShape3D
        if collision == null or not collision.shape is BoxShape3D:
            continue
        # Keep the shape local to this vehicle instead of mutating shared scene resources.
        var shape := collision.shape.duplicate() as BoxShape3D
        shape.size = Vector3(bounds.size.x * 0.97, maxf(bounds.end.y, 1.0), bounds.size.z * 0.97)
        collision.shape = shape
        var centre := bounds.get_center()
        collision.position = Vector3(centre.x, shape.size.y * 0.5, centre.z)
        break

func _boost_components(speed_abs: float) -> Dictionary:
    # Stage 3 compound boost: the supercharger fills the low/mid-range while
    # the twins take over as airflow rises. Twin front motors fill launch torque.
    var fraction := clampf(speed_abs / MAX_FORWARD_MPS, 0.0, 1.0)
    var supercharger := 4.8 * (1.0 - smoothstep(22.0, 58.0, speed_abs))
    var twin_turbos := 6.5 * smoothstep(6.0, 28.0, speed_abs) * (1.0 - 0.48 * fraction)
    var front_motors := 7.5 * (1.0 - smoothstep(12.0, FRONT_ELECTRIC_CUTOFF_MPS, speed_abs))
    return {"supercharger": supercharger, "twin_turbos": twin_turbos, "front_motors": front_motors}

func performance_state() -> Dictionary:
    return {
        "profile": performance_profile,
        "top_speed_kmh": MAX_FORWARD_MPS * 3.6,
        "front_electric_assist": front_electric_assist,
        "compound_boost": compound_boost,
        "downforce_accel": downforce_accel,
    }

static func shaped_steering_input(turn: float) -> float:
    var value := clampf(turn, -1.0, 1.0)
    if absf(value) < 0.001:
        return 0.0
    # More resolution around centre for touch sticks without reducing full lock.
    return signf(value) * pow(absf(value), STEERING_INPUT_EXPONENT)

static func steering_limit_for_speed(speed_abs: float) -> float:
    var speed := clampf(absf(speed_abs), 0.0, MAX_FORWARD_MPS)
    var reduction := smoothstep(0.0, STEERING_FULL_REDUCTION_MPS, speed)
    return deg_to_rad(lerpf(STEERING_LOW_SPEED_DEG, STEERING_HIGH_SPEED_DEG, reduction))

static func steering_response_rate(speed_abs: float, returning: bool) -> float:
    var speed_fraction := clampf(absf(speed_abs) / STEERING_FULL_REDUCTION_MPS, 0.0, 1.0)
    if returning:
        # Centre return stays decisive so a released touch input cannot leave
        # residual lock, while high-speed return remains smooth rather than snapping.
        return lerpf(10.5, 7.0, speed_fraction)
    return lerpf(8.0, 3.0, speed_fraction)

static func yaw_response_rate(speed_abs: float) -> float:
    return lerpf(11.0, 5.0, clampf(absf(speed_abs) / STEERING_FULL_REDUCTION_MPS, 0.0, 1.0))

static func lateral_grip_response(speed_abs: float, road: bool, parking_brake: bool) -> float:
    var response := 3.4
    if road:
        response = 9.0 + smoothstep(0.0, 55.0, absf(speed_abs)) * 3.5
    if parking_brake:
        response *= 0.22
    return response

func handling_state() -> Dictionary:
    return {
        "steer_input": _steer,
        "steering_angle": steering_angle,
        "yaw_rate": _yaw_rate_state,
        "speed_sensitive": true,
        "controlled_lateral_slip": true,
    }

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
    var speed_abs := absf(speed_mps)
    var road_downforce := minf(speed_abs * speed_abs * DOWNFORCE_COEFFICIENT, MAX_DOWNFORCE_ACCEL)
    downforce_accel = road_downforce if on_road else road_downforce * 0.16
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
        # Carbon-ceramic service braking, regen and aero load all contribute.
        var brake_deceleration := ((20.0 + downforce_accel * 0.30) if on_road else 8.5) * braking
        if not traction:
            brake_deceleration *= 0.1
        speed_mps = move_toward(speed_mps, 0.0, brake_deceleration * dt)
        front_electric_assist = 0.0
        compound_boost = 0.0
    elif absf(throttle) > 0.02 and traction:
        var limit := MAX_REVERSE_MPS if throttle < 0.0 else (MAX_FORWARD_MPS if on_road else GRASS_LIMIT_MPS)
        var speed_fraction := clampf(speed_abs / MAX_FORWARD_MPS, 0.0, 1.0)
        var boost := _boost_components(speed_abs)
        var base_engine := 7.4 - 2.8 * speed_fraction
        compound_boost = float(boost.supercharger) + float(boost.twin_turbos)
        front_electric_assist = float(boost.front_motors) if throttle > 0.0 and on_road else 0.0
        var acceleration := (base_engine + compound_boost + front_electric_assist) * absf(throttle)
        if throttle < 0.0:
            acceleration = base_engine * 0.52 * absf(throttle)
            compound_boost = 0.0
            front_electric_assist = 0.0
        if not on_road:
            acceleration *= 0.52
            compound_boost *= 0.40
        if speed_abs < limit:
            speed_mps += signf(throttle) * acceleration * dt
            speed_mps = clampf(speed_mps, -MAX_REVERSE_MPS, MAX_FORWARD_MPS)
    else:
        front_electric_assist = move_toward(front_electric_assist, 0.0, 18.0 * dt)
        compound_boost = move_toward(compound_boost, 0.0, 15.0 * dt)
    # The Stage 3 car has enough power to pull against real aero load at the
    # 378 km/h limiter; this term represents rolling + body drag, not downforce.
    var rolling_drag := 0.12 + absf(speed_mps) * absf(speed_mps) * 0.00045
    if not on_road:
        rolling_drag += 0.62 + absf(speed_mps) * absf(speed_mps) * 0.0035
        if speed_mps > GRASS_LIMIT_MPS:
            rolling_drag += 2.0 + (speed_mps - GRASS_LIMIT_MPS) * 0.30
    if traction:
        speed_mps = move_toward(speed_mps, 0.0, rolling_drag * dt)
    if absf(speed_mps) < 0.055 and absf(throttle) < 0.02:
        speed_mps = 0.0

    # Touch steering now has fine centre resolution, progressively slower rack
    # response and substantially less lock as speed rises. Released input gets
    # a separate centre-return rate so the wheel cannot remain partially locked.
    var shaped_turn := shaped_steering_input(turn)
    var returning := absf(shaped_turn) < 0.015
    var steer_rate := steering_response_rate(speed_abs, returning)
    _steer = move_toward(_steer, shaped_turn, dt * steer_rate)
    steering_angle = -_steer * steering_limit_for_speed(absf(speed_mps))

    var target_yaw_rate := speed_mps * tan(steering_angle) / wheelbase_m
    # Active aero turns speed into usable tyre load. At Vmax this adds roughly
    # 2.85 g of vertical load and lifts the lateral grip ceiling accordingly.
    var grip := (11.5 + downforce_accel * 0.65) if on_road else 4.8
    if handbrake:
        grip *= 0.62
    var yaw_limit := minf(1.28, grip / maxf(absf(speed_mps), 1.0))
    target_yaw_rate = clampf(target_yaw_rate, -yaw_limit, yaw_limit) if traction else 0.0
    _yaw_rate_state = lerpf(_yaw_rate_state, target_yaw_rate,
        1.0 - exp(-yaw_response_rate(speed_abs) * dt)) if traction else move_toward(_yaw_rate_state, 0.0, dt * 8.0)
    body.rotate_y(_yaw_rate_state * dt)
    _last_yaw_rate = _yaw_rate_state

    # Preserve a controlled amount of lateral velocity instead of snapping the
    # velocity vector to the new heading every frame. Normal tyre grip quickly
    # catches the slip; the handbrake deliberately releases lateral authority.
    var forward := -body.global_transform.basis.z
    var forward_2d := Vector2(forward.x, forward.z).normalized()
    var right_2d := Vector2(-forward_2d.y, forward_2d.x)
    var horizontal := Vector2(body.velocity.x, body.velocity.z)
    var longitudinal := horizontal.dot(forward_2d)
    var lateral := horizontal.dot(right_2d)
    var longitudinal_response := (18.0 + minf(downforce_accel * 0.14, 3.5)) if on_road else 6.5
    longitudinal = lerpf(longitudinal, speed_mps, 1.0 - exp(-longitudinal_response * dt)) if traction else longitudinal
    lateral *= exp(-lateral_grip_response(speed_abs, on_road, handbrake) * dt) if traction else 1.0
    horizontal = forward_2d * longitudinal + right_2d * lateral
    body.velocity.x = horizontal.x
    body.velocity.z = horizontal.y
    body.velocity.y = -(2.0 + downforce_accel) if traction else body.velocity.y - (23.0 + downforce_accel * 0.35) * dt
    var before := body.global_position
    body.move_and_slide()
    odometer_m += Vector2(body.global_position.x - before.x, body.global_position.z - before.z).length()
    if body.is_on_wall():
        speed_mps = Vector2(body.velocity.x, body.velocity.z).dot(Vector2(forward.x, forward.z))
    _last_acceleration = (speed_mps - previous_speed) / dt
    _update_visual(dt, forward, braking)
    var ratios := [480.0, 320.0, 235.0, 185.0, 145.0, 105.0, 72.0]
    var ratio: float = ratios[_gear_index()]
    var target_rpm := clampf(1000.0 + absf(speed_mps) * ratio + absf(throttle) * 700.0, 900.0, 8200.0) if occupied else 0.0
    engine_rpm = lerpf(engine_rpm, target_rpm, 1.0 - exp(-dt * 10.0))

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
    var body_pitch := clampf(_last_acceleration * 0.0030, -0.060, 0.038)
    var body_roll := clampf(-_last_yaw_rate * speed_mps * 0.0046, -0.065, 0.065)
    visual.call("update_motion", delta, speed_mps, steering_angle, braking, speed_mps < -0.15, occupied, body_pitch, body_roll)

func _gear_index() -> int:
    var forward_speed := absf(speed_mps)
    if forward_speed < 9.0:
        return 0
    if forward_speed < 17.0:
        return 1
    if forward_speed < 28.0:
        return 2
    if forward_speed < 42.0:
        return 3
    if forward_speed < 60.0:
        return 4
    if forward_speed < 82.0:
        return 5
    return 6

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
    _yaw_rate_state = 0.0
    steering_angle = 0.0
    brake_input = 0.0
    handbrake = false
    front_electric_assist = 0.0
    compound_boost = 0.0
    downforce_accel = 0.0
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
