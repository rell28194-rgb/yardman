extends RefCounted
class_name YardmanVehicleController

const ModelScript = preload("res://scripts/vehicle_model.gd")
const Catalog = preload("res://scripts/vehicle_catalog.gd")
const Powertrain = preload("res://scripts/vehicle_powertrain.gd")

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
var wheelbase_m := 2.56
var visual: Node3D
var vehicle_id := Catalog.DEFAULT_ID
var profile: Dictionary = Catalog.profile(Catalog.DEFAULT_ID)
var _steer := 0.0
var _ground_basis := Basis.IDENTITY
var _visual_scale := Vector3.ONE
var _last_acceleration := 0.0
var _last_yaw_rate := 0.0
var _last_throttle := 0.0
var _lateral_speed := 0.0
var _probe_normal := Vector3.UP
var _contact_ratio := 1.0
var _suspension_compression := 0.35
var _track_half_m := 0.72
var _headlights: Array[SpotLight3D] = []
var _current_gear := 0
var _shift_timer := 0.0
var _shift_count := 0
var _last_shift_direction := 0

func configure(vehicle: CharacterBody3D, requested_vehicle_id: String = "") -> void:
    body = vehicle
    body.floor_snap_length = 0.42
    body.floor_max_angle = deg_to_rad(45.0)
    body.floor_stop_on_slope = false
    body.floor_constant_speed = false
    apply_profile(requested_vehicle_id if not requested_vehicle_id.is_empty() else Catalog.DEFAULT_ID)

func apply_profile(requested_vehicle_id: String) -> void:
    profile = Catalog.profile(requested_vehicle_id)
    vehicle_id = str(profile.id)
    wheelbase_m = float(profile.wheelbase_m)
    _track_half_m = clampf(float(profile.track_width_m) * 0.5, 0.58, 0.96)
    if body != null:
        _rebuild_visual()
        _fit_profile_collision()
    engine_rpm = float(profile.idle_rpm) if occupied else 0.0
    reset_motion()

func profile_metadata() -> Dictionary:
    return profile.duplicate(true)

func audio_profile() -> String:
    return str(profile.get("audio_profile", "legacy_inline6"))

func _rebuild_visual() -> void:
    var old_visual := body.get_node_or_null("VisualRig")
    if old_visual != null:
        body.remove_child(old_visual)
        old_visual.queue_free()
    visual = ModelScript.new()
    visual.name = "VisualRig"
    body.add_child(visual)
    visual.call("build", str(profile.get("hero_scene", "")))
    var dedicated := bool(visual.get_meta("yardman_dedicated_vehicle_mesh", false))
    if dedicated or bool(profile.get("use_visual_wheelbase", false)):
        wheelbase_m = clampf(float(visual.get("wheelbase_m")), 1.8, 4.5)
    if dedicated:
        _track_half_m = clampf(float(visual.get("track_width_m")) * 0.5, 0.50, 1.40)
    var scale_data: Array = profile.get("visual_scale", [1.0, 1.0, 1.0])
    if not dedicated and scale_data.size() >= 3:
        visual.scale = Vector3(float(scale_data[0]), float(scale_data[1]), float(scale_data[2]))
    _visual_scale = visual.scale
    _make_headlights(_profile_bounds())
    _ground_basis = Basis.IDENTITY

func _profile_bounds() -> AABB:
    if visual != null and bool(visual.get_meta("yardman_dedicated_vehicle_mesh", false)):
        return visual.get("geometry_bounds")
    var dims: Array = profile.get("dimensions_m", [1.85, 1.30, 4.0])
    var width := float(dims[0]) if dims.size() > 0 else 1.85
    var height := float(dims[1]) if dims.size() > 1 else 1.30
    var length := float(dims[2]) if dims.size() > 2 else 4.0
    return AABB(Vector3(-width * 0.5, 0.0, -length * 0.5), Vector3(width, height, length))

func _make_headlights(bounds: AABB) -> void:
    _headlights.clear()
    var half_width := bounds.size.x * 0.5
    var lamp_x := clampf(half_width * 0.62, 0.48, 0.76)
    var lamp_y := clampf(bounds.position.y + bounds.size.y * 0.43, 0.52, 0.96)
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

func _fit_profile_collision() -> void:
    var bounds := _profile_bounds()
    if bool(profile.get("use_visual_wheelbase", false)) and visual != null and bool(visual.get("is_reference_model")):
        bounds = visual.get("geometry_bounds")
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

func _vector_is_finite(value: Vector3) -> bool:
    return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)

func _basis_is_finite(value: Basis) -> bool:
    return _vector_is_finite(value.x) and _vector_is_finite(value.y) and _vector_is_finite(value.z)

func _safe_normal(value: Vector3, fallback: Vector3 = Vector3.UP) -> Vector3:
    if not _vector_is_finite(value) or value.length_squared() < 0.000001:
        return fallback
    var result := value.normalized()
    return result if _vector_is_finite(result) else fallback

func _sample_ground_contacts() -> void:
    if body == null or not body.is_inside_tree() or body.get_world_3d() == null:
        _probe_normal = Vector3.UP
        _contact_ratio = 0.0
        return
    var space := body.get_world_3d().direct_space_state
    var axle_z := wheelbase_m * 0.50
    var top := float(profile.get("suspension_ray_top_m", 0.95))
    var ray_length := float(profile.get("suspension_ray_length_m", 1.65))
    var points: Array[Vector3] = [
        Vector3(-_track_half_m, top, -axle_z), Vector3(_track_half_m, top, -axle_z),
        Vector3(-_track_half_m, top, axle_z), Vector3(_track_half_m, top, axle_z),
    ]
    var normal_sum := Vector3.ZERO
    var compression_sum := 0.0
    var contacts := 0
    for point in points:
        var start: Vector3 = body.global_transform * point
        var finish: Vector3 = start - Vector3.UP * ray_length
        if not _vector_is_finite(start) or not _vector_is_finite(finish):
            continue
        var query := PhysicsRayQueryParameters3D.create(start, finish, 1)
        query.exclude = [body.get_rid()]
        query.collide_with_areas = false
        var hit: Dictionary = space.intersect_ray(query)
        if hit.is_empty():
            continue
        var hit_position: Vector3 = hit.get("position", start)
        var hit_normal: Vector3 = hit.get("normal", Vector3.UP)
        if not _vector_is_finite(hit_position):
            continue
        contacts += 1
        normal_sum += _safe_normal(hit_normal, Vector3.UP)
        var distance: float = start.distance_to(hit_position)
        if is_finite(distance):
            compression_sum += clampf((ray_length - distance) / 0.72, 0.0, 1.0)
    _contact_ratio = float(contacts) / 4.0
    if contacts > 0:
        _probe_normal = _safe_normal(normal_sum / float(contacts), Vector3.UP)
        var compression := compression_sum / float(contacts)
        if is_finite(compression):
            _suspension_compression = lerpf(_suspension_compression, compression, 0.32)
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
    _shift_timer = maxf(0.0, _shift_timer - dt)
    if occupied and speed_mps >= -0.15 and _shift_timer <= 0.0:
        var requested_gear: int = Powertrain.select_gear(profile, maxf(speed_mps, 0.0), _current_gear, throttle, engine_rpm)
        if requested_gear != _current_gear:
            _last_shift_direction = 1 if requested_gear > _current_gear else -1
            _current_gear = requested_gear
            _shift_timer = maxf(float(profile.get("shift_time_s", 0.24)), 0.0)
            _shift_count += 1
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
    var max_forward := float(profile.max_forward_mps)
    var max_reverse := float(profile.max_reverse_mps)
    var grass_limit := float(profile.grass_limit_mps)
    if braking > 0.01:
        var brake_deceleration := (float(profile.brake_decel_mps2) if on_road else float(profile.offroad_brake_decel_mps2)) * braking
        if handbrake and absf(turn) > 0.10 and absf(speed_mps) > 7.0:
            brake_deceleration *= 0.52
        if not traction:
            brake_deceleration *= 0.1
        speed_mps = move_toward(speed_mps, 0.0, brake_deceleration * dt)
    elif absf(throttle) > 0.02 and traction:
        var limit := max_reverse if throttle < 0.0 else (max_forward if on_road else grass_limit)
        var acceleration: float
        if throttle > 0.0:
            acceleration = Powertrain.drive_acceleration(profile, engine_rpm, _current_gear, speed_mps, throttle)
            acceleration *= Powertrain.shift_torque_factor(profile, _shift_timer)
        else:
            var reverse_fraction := clampf(absf(speed_mps) / maxf(max_reverse, 1.0), 0.0, 1.0)
            acceleration = lerpf(float(profile.acceleration_low_mps2), float(profile.acceleration_high_mps2), reverse_fraction) * absf(throttle) * float(profile.reverse_accel_factor)
        if not on_road:
            acceleration *= 0.70
        if absf(speed_mps) < limit:
            speed_mps += signf(throttle) * acceleration * dt
            speed_mps = clampf(speed_mps, -max_reverse, max_forward)
    var rolling_drag := float(profile.rolling_drag_base) + absf(speed_mps) * absf(speed_mps) * float(profile.aero_drag)
    if not on_road:
        rolling_drag += float(profile.offroad_drag_base) + absf(speed_mps) * absf(speed_mps) * float(profile.offroad_aero_drag)
        if speed_mps > grass_limit:
            rolling_drag += float(profile.offroad_overlimit_drag) + (speed_mps - grass_limit) * float(profile.offroad_overlimit_slope)
    if traction:
        speed_mps = move_toward(speed_mps, 0.0, rolling_drag * dt)
    if absf(speed_mps) < 0.055 and absf(throttle) < 0.02:
        speed_mps = 0.0
    _steer = move_toward(_steer, turn, dt * 6.5)
    var speed_fraction := clampf(absf(speed_mps) / maxf(max_forward, 1.0), 0.0, 1.0)
    var steering_limit := lerpf(deg_to_rad(float(profile.steering_low_deg)), deg_to_rad(float(profile.steering_high_deg)), pow(speed_fraction, 0.72))
    steering_angle = -_steer * steering_limit
    var yaw_rate := speed_mps * tan(steering_angle) / maxf(wheelbase_m, 0.5)
    var drift_mode := on_road and traction and absf(speed_mps) > 7.0 and absf(_steer) > 0.12 and (handbrake or drift_assist)
    var grip_accel := float(profile.grip_accel_mps2) if on_road else float(profile.offroad_grip_accel_mps2)
    if drift_mode:
        grip_accel = float(profile.drift_grip_assist_mps2) if drift_assist else float(profile.drift_grip_raw_mps2)
    elif handbrake:
        grip_accel *= 0.62
    var yaw_cap := float(profile.drift_yaw_cap) if drift_mode else float(profile.yaw_cap)
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
            var slip_fraction := float(profile.drift_slip_assist) if drift_assist else float(profile.drift_slip_raw)
            var slip_bonus := float(profile.drift_bonus_assist) if drift_assist else float(profile.drift_bonus_raw)
            var lateral_target := -_steer * minf(absf(speed_mps) * slip_fraction + slip_bonus, float(profile.drift_lateral_cap_mps))
            var slip_response := 3.7 if drift_assist else 2.6
            lateral = lerpf(lateral, lateral_target, 1.0 - exp(-slip_response * dt))
            lateral = clampf(lateral, -float(profile.drift_lateral_cap_mps), float(profile.drift_lateral_cap_mps))
        else:
            var lateral_response := float(profile.lateral_response) if on_road else float(profile.offroad_lateral_response)
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
    var target_rpm := Powertrain.target_rpm(profile, speed_mps, _current_gear, throttle) if occupied else 0.0
    var rpm_response := maxf(float(profile.get("rpm_response", 10.0)), 1.0)
    if _shift_timer > 0.0:
        rpm_response *= 1.35
    engine_rpm = lerpf(engine_rpm, target_rpm, 1.0 - exp(-dt * rpm_response))

func _update_visual(delta: float, forward: Vector3, braking: float) -> void:
    if visual == null:
        return
    var floor_normal := Vector3.UP
    if body != null and body.is_on_floor():
        floor_normal = _safe_normal(body.get_floor_normal(), Vector3.UP)
    var up := _safe_normal(_probe_normal, Vector3.UP) if _contact_ratio >= 0.25 else floor_normal
    var fallback_forward := Vector3.FORWARD
    if body != null and _basis_is_finite(body.global_basis):
        fallback_forward = _safe_normal(-body.global_basis.z, Vector3.FORWARD)
    var safe_forward := _safe_normal(forward, fallback_forward)
    var ahead := safe_forward.slide(up)
    if _vector_is_finite(ahead) and ahead.length_squared() > 0.01:
        ahead = _safe_normal(ahead, safe_forward)
        if absf(ahead.dot(up)) < 0.985 and body != null and _basis_is_finite(body.global_basis):
            var desired_basis := body.global_basis.inverse() * Basis.looking_at(ahead, up)
            if _basis_is_finite(desired_basis):
                if not _basis_is_finite(_ground_basis):
                    _ground_basis = Basis.IDENTITY
                var blended := _ground_basis.slerp(desired_basis, 1.0 - exp(-delta * 8.5)).orthonormalized()
                if _basis_is_finite(blended):
                    _ground_basis = blended
    if not _basis_is_finite(_ground_basis):
        _ground_basis = Basis.IDENTITY
    var safe_scale := _visual_scale if _vector_is_finite(_visual_scale) else Vector3.ONE
    visual.basis = _ground_basis.scaled_local(safe_scale)
    var suspension_y := lerpf(0.055, -0.035, _suspension_compression)
    if not is_finite(suspension_y):
        suspension_y = 0.0
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
    return clampi(_current_gear, 0, Powertrain.gear_count(profile) - 1)

func gear_index() -> int:
    return _gear_index()

func is_shifting() -> bool:
    return _shift_timer > 0.0

func transmission_snapshot() -> Dictionary:
    return {
        "gear_index": _gear_index(),
        "gear_label": gear_label(),
        "shifting": is_shifting(),
        "shift_time_remaining": _shift_timer,
        "shift_count": _shift_count,
        "last_shift_direction": _last_shift_direction,
        "transmission": str(profile.get("transmission", "automatic")),
        "final_drive": float(profile.get("final_drive", 1.0)),
    }

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
    _current_gear = 0
    _shift_timer = 0.0
    _shift_count = 0
    _last_shift_direction = 0
    engine_rpm = float(profile.get("idle_rpm", 900.0)) if occupied else 0.0
    _ground_basis = Basis.IDENTITY
    if body != null:
        body.velocity = Vector3.ZERO
    if visual != null:
        var safe_scale := _visual_scale if _vector_is_finite(_visual_scale) else Vector3.ONE
        visual.basis = Basis.IDENTITY.scaled_local(safe_scale)
        visual.position.y = 0.0
        visual.call("update_motion", 1.0, 0.0, 0.0, 0.0, false, occupied, 0.0, 0.0)
