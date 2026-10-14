extends RefCounted
class_name YardmanVehiclePowertrain

# Shared automatic-transmission / torque model. Catalog data supplies the
# character; the controller supplies state. Values are game tuning, not a claim
# that every named vehicle represents one exact production trim.

static func gear_count(profile: Dictionary) -> int:
    var ratios: Array = profile.get("gear_ratios", [3.5, 2.1, 1.4, 1.0, 0.75])
    return maxi(ratios.size(), 1)

static func gear_ratio(profile: Dictionary, gear_index: int) -> float:
    var ratios: Array = profile.get("gear_ratios", [3.5, 2.1, 1.4, 1.0, 0.75])
    if ratios.is_empty():
        return 1.0
    return maxf(float(ratios[clampi(gear_index, 0, ratios.size() - 1)]), 0.05)

static func torque_factor(profile: Dictionary, rpm: float) -> float:
    var curve: Array = profile.get("torque_curve", [[800.0, 0.60], [3000.0, 1.0], [6500.0, 0.72]])
    if curve.is_empty():
        return 1.0
    var first: Array = curve[0]
    if rpm <= float(first[0]):
        return clampf(float(first[1]), 0.05, 1.25)
    for index in range(1, curve.size()):
        var previous: Array = curve[index - 1]
        var current: Array = curve[index]
        var current_rpm := float(current[0])
        if rpm <= current_rpm:
            var low_rpm := float(previous[0])
            var span := maxf(current_rpm - low_rpm, 1.0)
            var weight := clampf((rpm - low_rpm) / span, 0.0, 1.0)
            return clampf(lerpf(float(previous[1]), float(current[1]), weight), 0.05, 1.25)
    var last: Array = curve[curve.size() - 1]
    return clampf(float(last[1]), 0.05, 1.25)

static func driveline_rpm(profile: Dictionary, speed_mps: float, gear_index: int) -> float:
    var radius := maxf(float(profile.get("wheel_radius_m", 0.34)), 0.15)
    var final_drive := maxf(float(profile.get("final_drive", 3.5)), 0.1)
    var ratio := float(profile.get("reverse_ratio", 3.2)) if speed_mps < -0.05 else gear_ratio(profile, gear_index)
    var wheel_rpm := absf(speed_mps) * 60.0 / (TAU * radius)
    return wheel_rpm * ratio * final_drive

static func target_rpm(profile: Dictionary, speed_mps: float, gear_index: int, throttle: float) -> float:
    var idle := float(profile.get("idle_rpm", 800.0))
    var redline := float(profile.get("redline_rpm", 6800.0))
    var driveline := driveline_rpm(profile, speed_mps, gear_index)
    var load := clampf(absf(throttle), 0.0, 1.0)
    # Torque-converter/clutch slip lets a stationary automatic respond to the
    # accelerator instead of sounding electrically locked to wheel speed.
    var launch_blend := 1.0 - smoothstep(0.35, 2.4, absf(speed_mps))
    var free_rev := idle + (redline - idle) * float(profile.get("launch_free_rev_fraction", 0.34)) * load * launch_blend
    var throttle_lift := float(profile.get("throttle_rpm_boost", 500.0)) * load * (1.0 - launch_blend * 0.65)
    return clampf(maxf(driveline, free_rev) + throttle_lift, idle * 0.92, redline)

static func select_gear(profile: Dictionary, speed_mps: float, current_gear: int, throttle: float, engine_rpm: float) -> int:
    var count := gear_count(profile)
    var gear := clampi(current_gear, 0, count - 1)
    if speed_mps < -0.15:
        return 0
    var load := clampf(absf(throttle), 0.0, 1.0)
    var shift_up_light := float(profile.get("shift_up_light_rpm", float(profile.get("redline_rpm", 6800.0)) * 0.52))
    var shift_up_full := float(profile.get("shift_up_rpm", float(profile.get("redline_rpm", 6800.0)) * 0.90))
    var up_threshold := lerpf(shift_up_light, shift_up_full, pow(load, 0.72))
    var down_threshold := float(profile.get("shift_down_rpm", 1450.0))
    var redline := float(profile.get("redline_rpm", 6800.0))

    if engine_rpm >= up_threshold and gear < count - 1:
        return gear + 1

    if gear > 0:
        var lower_rpm := target_rpm(profile, maxf(speed_mps, 0.0), gear - 1, 0.0)
        var safe_downshift := lower_rpm < redline * 0.94
        var kickdown := load >= float(profile.get("kickdown_throttle", 0.76)) and lower_rpm < shift_up_full * 0.98
        if safe_downshift and (engine_rpm <= down_threshold or kickdown):
            return gear - 1
    return gear

static func drive_acceleration(profile: Dictionary, rpm: float, gear_index: int, speed_mps: float, throttle: float) -> float:
    var max_speed := maxf(float(profile.get("max_forward_mps", 60.0)), 1.0)
    var speed_fraction := clampf(absf(speed_mps) / max_speed, 0.0, 1.0)
    var tuned := lerpf(float(profile.get("acceleration_low_mps2", 7.0)), float(profile.get("acceleration_high_mps2", 4.0)), pow(speed_fraction, 0.88))

    var torque_nm := maxf(float(profile.get("peak_torque_nm", 320.0)), 10.0) * torque_factor(profile, rpm)
    var final_drive := maxf(float(profile.get("final_drive", 3.5)), 0.1)
    var efficiency := clampf(float(profile.get("drivetrain_efficiency", 0.88)), 0.50, 1.0)
    var radius := maxf(float(profile.get("wheel_radius_m", 0.34)), 0.15)
    var mass := maxf(float(profile.get("mass_kg", 1500.0)), 200.0)
    var wheel_force := torque_nm * gear_ratio(profile, gear_index) * final_drive * efficiency / radius
    var physical := wheel_force / mass
    var blend := clampf(float(profile.get("powertrain_physics_blend", 0.48)), 0.0, 0.80)
    var combined := lerpf(tuned, physical, blend)
    # Existing acceleration tuning remains the accessibility envelope while the
    # physical branch gives each gear/final-drive/torque curve real influence.
    combined = clampf(combined, tuned * 0.52, tuned * 1.32)
    return combined * clampf(absf(throttle), 0.0, 1.0)

static func shift_torque_factor(profile: Dictionary, shift_timer: float) -> float:
    if shift_timer <= 0.0:
        return 1.0
    return clampf(float(profile.get("shift_torque_factor", 0.32)), 0.05, 1.0)
