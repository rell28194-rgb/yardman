extends RefCounted
class_name YardmanVehicleController

const Catalog = preload("res://scripts/vehicle_catalog.gd")
const FleetModel = preload("res://scripts/fleet_vehicle_model.gd")
const FallbackModel = preload("res://scripts/vehicle_model.gd")
const PROFILE_CROWN_STAGE3 := "crown_stage3_compound_hybrid"
const MAX_FORWARD_MPS := 105.0
const MAX_REVERSE_MPS := 12.0
const GRASS_LIMIT_MPS := 18.0
const WHEELBASE_M := 2.56
const FRONT_ELECTRIC_CUTOFF_MPS := 52.0
const DOWNFORCE_COEFFICIENT := 0.0032
const MAX_DOWNFORCE_ACCEL := 28.0
const STEERING_LOW_SPEED_DEG := 38.0
const STEERING_HIGH_SPEED_DEG := 7.0
const STEERING_FULL_REDUCTION_MPS := 72.0
const STEERING_INPUT_EXPONENT := 1.08
const ROAD_LATERAL_ACCEL := 13.5

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

# Runtime values default to the already owner-tested legacy Crown profile. A
# source-reconciled vehicle may override these through its vehicle definition.
# This keeps the existing game driveable while making shared/fake dynamics
# explicit instead of silently pretending every Fleet64 car has unique physics.
var max_forward_mps := MAX_FORWARD_MPS
var max_reverse_mps := MAX_REVERSE_MPS
var grass_limit_mps := GRASS_LIMIT_MPS
var front_electric_cutoff_mps := FRONT_ELECTRIC_CUTOFF_MPS
var downforce_coefficient := DOWNFORCE_COEFFICIENT
var max_downforce_accel := MAX_DOWNFORCE_ACCEL
var steering_low_speed_deg := STEERING_LOW_SPEED_DEG
var steering_high_speed_deg := STEERING_HIGH_SPEED_DEG
var steering_full_reduction_mps := STEERING_FULL_REDUCTION_MPS
var road_lateral_accel := ROAD_LATERAL_ACCEL
var service_brake_decel_mps2 := 20.0
var offroad_brake_decel_mps2 := 8.5
var acceleration_low_mps2 := 7.4
var acceleration_high_mps2 := 4.6
var reverse_accel_scale := 0.52
var rolling_drag_base := 0.12
var rolling_drag_quadratic := 0.00045
var offroad_drag_base := 0.62
var offroad_drag_quadratic := 0.0035
var idle_rpm := 900.0
var redline_rpm := 8200.0
var rpm_throttle_add := 700.0
var boost_supercharger_peak := 4.8
var boost_turbo_peak := 6.5
var boost_front_motor_peak := 7.5
var boost_supercharger_fade_start := 22.0
var boost_supercharger_fade_end := 58.0
var boost_turbo_start := 6.0
var boost_turbo_full := 28.0
var boost_front_motor_fade_start := 12.0
var _gear_speed_thresholds: Array[float] = [9.0, 17.0, 28.0, 42.0, 60.0, 82.0]
var _gear_rpm_multipliers: Array[float] = [480.0, 320.0, 235.0, 185.0, 145.0, 105.0, 72.0]
var _active_vehicle_id := ""
var _dynamics_source_backed := false

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
    var old_visual := body.get_node_or_null("VisualRig")
    if old_visual != null:
        body.remove_child(old_visual)
        old_visual.queue_free()

    # The production default is the exact Crown hero. Never route it through the
    # legacy road-car alias / procedural sedan path. Lightweight builds without
    # owner media may still use an explicitly unbranded fallback so traversal is
    # possible, but that fallback is marked invalid and must never be presented
    # as the Crown by garage/runtime validation.
    var hero := Catalog.hero_scene(Catalog.DEFAULT_ID)
    var candidate := FleetModel.new() as Node3D
    candidate.call("build", hero)
    var exact_crown := not bool(candidate.get_meta("yardman_hero_asset_missing_or_invalid", false)) \
        and bool(candidate.get_meta("yardman_dedicated_vehicle_mesh", false)) \
        and str(candidate.get_meta("yardman_requested_hero_scene", "")) == hero
    if exact_crown:
        visual = candidate
        body.set_meta("yardman_vehicle_identity_valid", true)
        body.set_meta("yardman_vehicle_identity", Catalog.DEFAULT_ID)
    else:
        candidate.free()
        visual = FallbackModel.new()
        visual.call("build")
        body.set_meta("yardman_vehicle_identity_valid", false)
        body.set_meta("yardman_vehicle_identity", "fallback_unbranded")
    visual.name = "VisualRig"
    body.add_child(visual)
    wheelbase_m = clampf(float(visual.get("wheelbase_m")), 1.8, 4.5)
    if bool(visual.get("is_reference_model")):
        _fit_reference_collision()
    _ground_basis = Basis.IDENTITY
    _sync_visual_profile(true)

func apply_vehicle_profile(vehicle_id: String) -> void:
    _reset_dynamics_defaults()
    _active_vehicle_id = vehicle_id
    var profile := Catalog.profile(vehicle_id)
    var dynamics_value = profile.get("dynamics", {})
    var dynamics: Dictionary = dynamics_value if dynamics_value is Dictionary else {}
    _dynamics_source_backed = not dynamics.is_empty() and bool(profile.get("source_backed", false))

    if dynamics.is_empty():
        performance_profile = PROFILE_CROWN_STAGE3 if vehicle_id == Catalog.DEFAULT_ID else "legacy_shared_crown_stage3:%s" % vehicle_id
    else:
        performance_profile = str(dynamics.get("profile_id", "source:%s" % vehicle_id))
        max_forward_mps = _number(dynamics, "top_speed_mps", max_forward_mps, 5.0, 180.0)
        max_reverse_mps = _number(dynamics, "reverse_speed_mps", max_reverse_mps, 1.0, 40.0)
        grass_limit_mps = _number(dynamics, "offroad_speed_limit_mps", grass_limit_mps, 2.0, 80.0)
        acceleration_low_mps2 = _number(dynamics, "acceleration_low_mps2", acceleration_low_mps2, 0.5, 40.0)
        acceleration_high_mps2 = _number(dynamics, "acceleration_high_mps2", acceleration_high_mps2, 0.1, 30.0)
        reverse_accel_scale = _number(dynamics, "reverse_accel_scale", reverse_accel_scale, 0.05, 1.5)
        service_brake_decel_mps2 = _number(dynamics, "service_brake_decel_mps2", service_brake_decel_mps2, 1.0, 60.0)
        offroad_brake_decel_mps2 = _number(dynamics, "offroad_brake_decel_mps2", offroad_brake_decel_mps2, 0.5, 40.0)
        road_lateral_accel = _number(dynamics, "road_lateral_accel_mps2", road_lateral_accel, 1.0, 35.0)
        downforce_coefficient = _number(dynamics, "downforce_coefficient", downforce_coefficient, 0.0, 0.02)
        max_downforce_accel = _number(dynamics, "max_downforce_accel_mps2", max_downforce_accel, 0.0, 80.0)
        steering_low_speed_deg = _number(dynamics, "steering_low_speed_deg", steering_low_speed_deg, 5.0, 65.0)
        steering_high_speed_deg = _number(dynamics, "steering_high_speed_deg", steering_high_speed_deg, 1.0, 25.0)
        steering_full_reduction_mps = _number(dynamics, "steering_full_reduction_mps", steering_full_reduction_mps, 5.0, 120.0)
        idle_rpm = _number(dynamics, "idle_rpm", idle_rpm, 300.0, 3000.0)
        redline_rpm = _number(dynamics, "redline_rpm", redline_rpm, idle_rpm + 500.0, 20000.0)
        rpm_throttle_add = _number(dynamics, "rpm_throttle_add", rpm_throttle_add, 0.0, 4000.0)
        rolling_drag_base = _number(dynamics, "rolling_drag_base", rolling_drag_base, 0.0, 3.0)
        rolling_drag_quadratic = _number(dynamics, "rolling_drag_quadratic", rolling_drag_quadratic, 0.0, 0.02)
        offroad_drag_base = _number(dynamics, "offroad_drag_base", offroad_drag_base, 0.0, 6.0)
        offroad_drag_quadratic = _number(dynamics, "offroad_drag_quadratic", offroad_drag_quadratic, 0.0, 0.05)
        _apply_boost_profile(dynamics.get("boost", {}))
        _gear_speed_thresholds = _float_array(dynamics.get("gear_speed_thresholds_mps", []), _gear_speed_thresholds, 1.0, 170.0)
        _gear_rpm_multipliers = _float_array(dynamics.get("gear_rpm_multipliers", []), _gear_rpm_multipliers, 1.0, 2000.0)

    engine_rpm = idle_rpm if occupied else 0.0
    if body != null:
        body.set_meta("yardman_vehicle_identity", vehicle_id)
        body.set_meta("yardman_dynamics_source_backed", _dynamics_source_backed)
        body.set_meta("yardman_performance_profile", performance_profile)

func _sync_visual_profile(force := false) -> void:
    if visual == null:
        return
    var hero := str(visual.get_meta("yardman_requested_hero_scene", ""))
    var resolved := Catalog.vehicle_id_for_hero_scene(hero)
    if resolved.is_empty() and body != null:
        var body_id := str(body.get_meta("yardman_vehicle_identity", ""))
        if Catalog.has(body_id):
            resolved = body_id
    if resolved.is_empty():
        resolved = Catalog.DEFAULT_ID
    if force or resolved != _active_vehicle_id:
        apply_vehicle_profile(resolved)

func _reset_dynamics_defaults() -> void:
    max_forward_mps = MAX_FORWARD_MPS
    max_reverse_mps = MAX_REVERSE_MPS
    grass_limit_mps = GRASS_LIMIT_MPS
    front_electric_cutoff_mps = FRONT_ELECTRIC_CUTOFF_MPS
    downforce_coefficient = DOWNFORCE_COEFFICIENT
    max_downforce_accel = MAX_DOWNFORCE_ACCEL
    steering_low_speed_deg = STEERING_LOW_SPEED_DEG
    steering_high_speed_deg = STEERING_HIGH_SPEED_DEG
    steering_full_reduction_mps = STEERING_FULL_REDUCTION_MPS
    road_lateral_accel = ROAD_LATERAL_ACCEL
    service_brake_decel_mps2 = 20.0
    offroad_brake_decel_mps2 = 8.5
    acceleration_low_mps2 = 7.4
    acceleration_high_mps2 = 4.6
    reverse_accel_scale = 0.52
    rolling_drag_base = 0.12
    rolling_drag_quadratic = 0.00045
    offroad_drag_base = 0.62
    offroad_drag_quadratic = 0.0035
    idle_rpm = 900.0
    redline_rpm = 8200.0
    rpm_throttle_add = 700.0
    boost_supercharger_peak = 4.8
    boost_turbo_peak = 6.5
    boost_front_motor_peak = 7.5
    boost_supercharger_fade_start = 22.0
    boost_supercharger_fade_end = 58.0
    boost_turbo_start = 6.0
    boost_turbo_full = 28.0
    boost_front_motor_fade_start = 12.0
    _gear_speed_thresholds = [9.0, 17.0, 28.0, 42.0, 60.0, 82.0]
    _gear_rpm_multipliers = [480.0, 320.0, 235.0, 185.0, 145.0, 105.0, 72.0]
    _dynamics_source_backed = false

func _apply_boost_profile(value) -> void:
    if not value is Dictionary:
        return
    var boost: Dictionary = value
    # A source-backed profile that declares boost owns the boost contract. Missing
    # components mean zero rather than inheriting the Crown's compound system.
    boost_supercharger_peak = _number(boost, "supercharger_peak_mps2", 0.0, 0.0, 30.0)
    boost_turbo_peak = _number(boost, "turbo_peak_mps2", 0.0, 0.0, 30.0)
    boost_front_motor_peak = _number(boost, "front_motor_peak_mps2", 0.0, 0.0, 30.0)
    front_electric_cutoff_mps = _number(boost, "front_motor_cutoff_mps", front_electric_cutoff_mps, 1.0, 150.0)
    boost_supercharger_fade_start = _number(boost, "supercharger_fade_start_mps", boost_supercharger_fade_start, 0.0, 150.0)
    boost_supercharger_fade_end = _number(boost, "supercharger_fade_end_mps", boost_supercharger_fade_end, boost_supercharger_fade_start + 0.1, 180.0)
    boost_turbo_start = _number(boost, "turbo_start_mps", boost_turbo_start, 0.0, 150.0)
    boost_turbo_full = _number(boost, "turbo_full_mps", boost_turbo_full, boost_turbo_start + 0.1, 180.0)
    boost_front_motor_fade_start = _number(boost, "front_motor_fade_start_mps", boost_front_motor_fade_start, 0.0, 150.0)

func _number(values: Dictionary, key: String, fallback: float, minimum: float, maximum: float) -> float:
    if not values.has(key):
        return fallback
    return clampf(float(values.get(key)), minimum, maximum)

func _float_array(value, fallback: Array[float], minimum: float, maximum: float) -> Array[float]:
    if not value is Array or (value as Array).is_empty():
        return fallback.duplicate()
    var result: Array[float] = []
    for raw_value in value as Array:
        result.append(clampf(float(raw_value), minimum, maximum))
    return result

func _fit_reference_collision() -> void:
    var bounds: AABB = visual.get("geometry_bounds")
    for node in body.find_children("*", "CollisionShape3D", true, false):
        var collision := node as CollisionShape3D
        if collision == null or not collision.shape is BoxShape3D:
            continue
        var shape := collision.shape.duplicate() as BoxShape3D
        shape.size = Vector3(bounds.size.x * 0.97, maxf(bounds.end.y, 1.0), bounds.size.z * 0.97)
        collision.shape = shape
        var centre := bounds.get_center()
        collision.position = Vector3(centre.x, shape.size.y * 0.5, centre.z)
        break

func _boost_components(speed_abs: float) -> Dictionary:
    var fraction := clampf(speed_abs / maxf(max_forward_mps, 1.0), 0.0, 1.0)
    var supercharger := boost_supercharger_peak * (1.0 - smoothstep(boost_supercharger_fade_start, boost_supercharger_fade_end, speed_abs))
    var twin_turbos := boost_turbo_peak * smoothstep(boost_turbo_start, boost_turbo_full, speed_abs) * (1.0 - 0.48 * fraction)
    var front_motors := boost_front_motor_peak * (1.0 - smoothstep(boost_front_motor_fade_start, front_electric_cutoff_mps, speed_abs))
    return {"supercharger": supercharger, "twin_turbos": twin_turbos, "front_motors": front_motors}

func performance_state() -> Dictionary:
    return {
        "profile": performance_profile,
        "vehicle_id": _active_vehicle_id,
        "source_backed": _dynamics_source_backed,
        "top_speed_kmh": max_forward_mps * 3.6,
        "front_electric_assist": front_electric_assist,
        "compound_boost": compound_boost,
        "downforce_accel": downforce_accel,
    }

static func shaped_steering_input(turn: float) -> float:
    var value := clampf(turn, -1.0, 1.0)
    if absf(value) < 0.001:
        return 0.0
    # TouchControls already removes and rescales its deadzone. Keep only a very
    # light response curve here so a normal thumb displacement still commands a
    # useful steering angle instead of being damped twice.
    return signf(value) * pow(absf(value), STEERING_INPUT_EXPONENT)

static func steering_limit_for_speed(speed_abs: float) -> float:
    var speed := clampf(absf(speed_abs), 0.0, MAX_FORWARD_MPS)
    var reduction := smoothstep(0.0, STEERING_FULL_REDUCTION_MPS, speed)
    return deg_to_rad(lerpf(STEERING_LOW_SPEED_DEG, STEERING_HIGH_SPEED_DEG, reduction))

static func steering_response_rate(speed_abs: float, returning: bool) -> float:
    var speed_fraction := clampf(absf(speed_abs) / STEERING_FULL_REDUCTION_MPS, 0.0, 1.0)
    if returning:
        return lerpf(12.0, 7.5, speed_fraction)
    return lerpf(10.5, 3.8, speed_fraction)

static func yaw_response_rate(speed_abs: float) -> float:
    return lerpf(12.0, 5.0, clampf(absf(speed_abs) / STEERING_FULL_REDUCTION_MPS, 0.0, 1.0))

static func lateral_grip_response(speed_abs: float, road: bool, parking_brake: bool) -> float:
    var response := 3.4
    if road:
        response = 10.5 + smoothstep(0.0, 55.0, absf(speed_abs)) * 4.0
    if parking_brake:
        response *= 0.22
    return response

static func minimum_turn_radius(wheelbase: float = 2.85) -> float:
    return maxf(wheelbase, 0.1) / tan(deg_to_rad(STEERING_LOW_SPEED_DEG))

func _steering_limit_current(speed_abs: float) -> float:
    var speed := clampf(absf(speed_abs), 0.0, max_forward_mps)
    var reduction := smoothstep(0.0, steering_full_reduction_mps, speed)
    return deg_to_rad(lerpf(steering_low_speed_deg, steering_high_speed_deg, reduction))

func _steering_response_current(speed_abs: float, returning: bool) -> float:
    var speed_fraction := clampf(absf(speed_abs) / maxf(steering_full_reduction_mps, 1.0), 0.0, 1.0)
    if returning:
        return lerpf(12.0, 7.5, speed_fraction)
    return lerpf(10.5, 3.8, speed_fraction)

func _yaw_response_current(speed_abs: float) -> float:
    return lerpf(12.0, 5.0, clampf(absf(speed_abs) / maxf(steering_full_reduction_mps, 1.0), 0.0, 1.0))

func _lateral_grip_current(speed_abs: float, road: bool, parking_brake: bool) -> float:
    var response := 3.4
    if road:
        response = maxf(4.0, road_lateral_accel - 3.0) + smoothstep(0.0, 55.0, absf(speed_abs)) * 4.0
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
        "vehicle_id": _active_vehicle_id,
        "source_backed": _dynamics_source_backed,
    }

func step(delta: float, throttle: float, turn: float, ready: bool) -> void:
    if body == null or not ready or delta <= 0.0:
        return
    _sync_visual_profile()
    var dt := minf(delta, 0.1)
    throttle = clampf(throttle, -1.0, 1.0) if occupied else 0.0
    turn = clampf(turn, -1.0, 1.0) if occupied else 0.0
    _last_throttle = throttle
    var previous_speed := speed_mps
    var speed_abs := absf(speed_mps)
    var road_downforce := minf(speed_abs * speed_abs * downforce_coefficient, max_downforce_accel)
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
        var brake_deceleration := ((service_brake_decel_mps2 + downforce_accel * 0.30) if on_road else offroad_brake_decel_mps2) * braking
        if not traction:
            brake_deceleration *= 0.1
        speed_mps = move_toward(speed_mps, 0.0, brake_deceleration * dt)
        front_electric_assist = 0.0
        compound_boost = 0.0
    elif absf(throttle) > 0.02 and traction:
        var limit := max_reverse_mps if throttle < 0.0 else (max_forward_mps if on_road else grass_limit_mps)
        var speed_fraction := clampf(speed_abs / maxf(max_forward_mps, 1.0), 0.0, 1.0)
        var boost := _boost_components(speed_abs)
        var base_engine := lerpf(acceleration_low_mps2, acceleration_high_mps2, speed_fraction)
        compound_boost = float(boost.supercharger) + float(boost.twin_turbos)
        front_electric_assist = float(boost.front_motors) if throttle > 0.0 and on_road else 0.0
        var acceleration := (base_engine + compound_boost + front_electric_assist) * absf(throttle)
        if throttle < 0.0:
            acceleration = base_engine * reverse_accel_scale * absf(throttle)
            compound_boost = 0.0
            front_electric_assist = 0.0
        if not on_road:
            acceleration *= 0.52
            compound_boost *= 0.40
        if speed_abs < limit:
            speed_mps += signf(throttle) * acceleration * dt
            speed_mps = clampf(speed_mps, -max_reverse_mps, max_forward_mps)
    else:
        front_electric_assist = move_toward(front_electric_assist, 0.0, 18.0 * dt)
        compound_boost = move_toward(compound_boost, 0.0, 15.0 * dt)
    var rolling_drag := rolling_drag_base + absf(speed_mps) * absf(speed_mps) * rolling_drag_quadratic
    if not on_road:
        rolling_drag += offroad_drag_base + absf(speed_mps) * absf(speed_mps) * offroad_drag_quadratic
        if speed_mps > grass_limit_mps:
            rolling_drag += 2.0 + (speed_mps - grass_limit_mps) * 0.30
    if traction:
        speed_mps = move_toward(speed_mps, 0.0, rolling_drag * dt)
    if absf(speed_mps) < 0.055 and absf(throttle) < 0.02:
        speed_mps = 0.0

    var shaped_turn := shaped_steering_input(turn)
    var returning := absf(shaped_turn) < 0.015
    var steer_rate := _steering_response_current(speed_abs, returning)
    _steer = move_toward(_steer, shaped_turn, dt * steer_rate)
    steering_angle = -_steer * _steering_limit_current(absf(speed_mps))

    var target_yaw_rate := speed_mps * tan(steering_angle) / wheelbase_m
    var grip := (road_lateral_accel + downforce_accel * 0.65) if on_road else 4.8
    if handbrake:
        grip *= 0.62
    var yaw_limit := minf(1.35, grip / maxf(absf(speed_mps), 1.0))
    target_yaw_rate = clampf(target_yaw_rate, -yaw_limit, yaw_limit) if traction else 0.0
    _yaw_rate_state = lerpf(_yaw_rate_state, target_yaw_rate,
        1.0 - exp(-_yaw_response_current(speed_abs) * dt)) if traction else move_toward(_yaw_rate_state, 0.0, dt * 8.0)
    body.rotate_y(_yaw_rate_state * dt)
    _last_yaw_rate = _yaw_rate_state

    var forward := -body.global_transform.basis.z
    var forward_2d := Vector2(forward.x, forward.z).normalized()
    var right_2d := Vector2(-forward_2d.y, forward_2d.x)
    var horizontal := Vector2(body.velocity.x, body.velocity.z)
    var longitudinal := horizontal.dot(forward_2d)
    var lateral := horizontal.dot(right_2d)
    var longitudinal_response := (18.0 + minf(downforce_accel * 0.14, 3.5)) if on_road else 6.5
    longitudinal = lerpf(longitudinal, speed_mps, 1.0 - exp(-longitudinal_response * dt)) if traction else longitudinal
    lateral *= exp(-_lateral_grip_current(speed_abs, on_road, handbrake) * dt) if traction else 1.0
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
    var gear_index := _gear_index()
    var ratio_index := mini(gear_index, _gear_rpm_multipliers.size() - 1)
    var ratio := _gear_rpm_multipliers[ratio_index] if ratio_index >= 0 else 1.0
    var target_rpm := clampf(idle_rpm + absf(speed_mps) * ratio + absf(throttle) * rpm_throttle_add, idle_rpm, redline_rpm) if occupied else 0.0
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
    for index in range(_gear_speed_thresholds.size()):
        if forward_speed < _gear_speed_thresholds[index]:
            return index
    return _gear_speed_thresholds.size()

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
    engine_rpm = idle_rpm if occupied else 0.0
    _ground_basis = Basis.IDENTITY
    if body != null:
        body.velocity = Vector3.ZERO
    if visual != null:
        visual.basis = Basis.IDENTITY
        visual.call("update_motion", 1.0, 0.0, 0.0, 0.0, false, occupied, 0.0, 0.0)
