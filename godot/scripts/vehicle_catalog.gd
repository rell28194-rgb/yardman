extends RefCounted
class_name YardmanVehicleCatalog

const FleetRegistry = preload("res://scripts/vehicle_fleet_registry.gd")

# Owner candidate policy: Crown remains the baseline Beta hero. Mark X and the
# 992 experiment are retired and must never re-enter a selectable/runtime roster.
const DEFAULT_ID := "toyota_crown"
const SCRAPPED_IDS := ["toyota_mark_x", "port_royal_992"]

static func _base_profile() -> Dictionary:
    return {
        "id": "fleet_base", "manufacturer": "Yardman", "display_name": "Fleet Vehicle", "drivetrain": "RWD", "hero_scene": "",
        "mass_kg": 1580.0, "wheelbase_m": 2.56, "use_visual_wheelbase": false, "track_width_m": 1.44, "cg_height_m": 0.55,
        "dimensions_m": [1.85, 1.30, 4.00], "visual_scale": [1.0, 1.0, 1.0], "wheel_radius_m": 0.35,
        "max_forward_mps": 58.0, "max_reverse_mps": 7.0, "grass_limit_mps": 17.0,
        "acceleration_low_mps2": 7.6, "acceleration_high_mps2": 4.6, "reverse_accel_factor": 0.67,
        "brake_decel_mps2": 12.0, "offroad_brake_decel_mps2": 7.2,
        "steering_low_deg": 36.0, "steering_high_deg": 13.0,
        "grip_accel_mps2": 11.5, "offroad_grip_accel_mps2": 6.2, "drift_grip_assist_mps2": 10.5, "drift_grip_raw_mps2": 9.2,
        "yaw_cap": 1.40, "drift_yaw_cap": 1.55, "lateral_response": 7.2, "offroad_lateral_response": 4.8,
        "drift_lateral_cap_mps": 9.5, "drift_slip_assist": 0.38, "drift_slip_raw": 0.30, "drift_bonus_assist": 2.2, "drift_bonus_raw": 0.9,
        "rolling_drag_base": 0.085, "aero_drag": 0.00072, "offroad_drag_base": 0.68, "offroad_aero_drag": 0.0037,
        "offroad_overlimit_drag": 2.2, "offroad_overlimit_slope": 0.32,
        "suspension_ray_top_m": 0.95, "suspension_ray_length_m": 1.65,
        "transmission": "6-speed automatic", "peak_torque_nm": 330.0,
        "gear_ratios": [3.82, 2.20, 1.52, 1.22, 1.00, 0.82], "final_drive": 3.55, "reverse_ratio": 3.33,
        "drivetrain_efficiency": 0.87, "powertrain_physics_blend": 0.45,
        "torque_curve": [[900.0, 0.60], [1800.0, 0.82], [3200.0, 1.00], [5000.0, 0.94], [6900.0, 0.70]],
        "shift_up_light_rpm": 3000.0, "shift_up_rpm": 6250.0, "shift_down_rpm": 1500.0,
        "shift_time_s": 0.28, "shift_torque_factor": 0.34, "kickdown_throttle": 0.76, "launch_free_rev_fraction": 0.34, "rpm_response": 10.5,
        "gear_speed_mps": [9.0, 18.0, 29.0, 42.0], "rpm_per_mps": [405.0, 245.0, 178.0, 132.0, 101.0],
        "idle_rpm": 900.0, "redline_rpm": 6900.0, "throttle_rpm_boost": 520.0,
        "paint_rgb": [0.14, 0.31, 0.37], "audio_profile": "legacy_inline6", "camera_distance_m": 7.8,
    }

static func _crown_profile() -> Dictionary:
    var result := _base_profile()
    result.merge({
        "id": "toyota_crown", "manufacturer": "Toyota", "display_name": "Toyota Crown", "hero_scene": "toyota_crown_2013.glb",
        "mass_kg": 1710.0, "wheelbase_m": 2.85, "track_width_m": 1.55, "cg_height_m": 0.54,
        "dimensions_m": [1.80, 1.46, 4.89], "visual_scale": [0.973, 1.123, 1.223], "wheel_radius_m": 0.34,
        "max_forward_mps": 61.0, "grass_limit_mps": 15.5,
        "acceleration_low_mps2": 6.7, "acceleration_high_mps2": 3.8,
        "brake_decel_mps2": 11.4, "steering_low_deg": 35.0, "steering_high_deg": 12.0,
        "transmission": "8-speed automatic", "peak_torque_nm": 350.0,
        "gear_ratios": [4.71, 3.14, 2.11, 1.67, 1.28, 1.00, 0.84, 0.67], "final_drive": 3.13, "reverse_ratio": 3.32,
        "torque_curve": [[720.0, 0.56], [1600.0, 0.80], [2800.0, 0.96], [3900.0, 1.00], [5200.0, 0.92], [6600.0, 0.68]],
        "idle_rpm": 720.0, "redline_rpm": 6600.0, "audio_profile": "crown_v6", "camera_distance_m": 8.1,
        "paint_rgb": [0.055, 0.070, 0.090],
    }, true)
    return result

static func _allowed_fleet_ids() -> Array:
    var result: Array = []
    for vehicle_id in FleetRegistry.ids():
        var id := str(vehicle_id)
        if id in SCRAPPED_IDS:
            continue
        result.append(id)
    return result

static func profile(vehicle_id: String) -> Dictionary:
    if vehicle_id in SCRAPPED_IDS:
        push_error("Scrapped Yardman vehicle selector requested: %s" % vehicle_id)
        return _crown_profile()
    if vehicle_id == DEFAULT_ID:
        return _crown_profile()
    if FleetRegistry.has(vehicle_id):
        var result := _base_profile()
        var recovered := FleetRegistry.entry(vehicle_id)
        for key in recovered.keys():
            result[key] = recovered[key]
        return result
    return _crown_profile()

static func has(vehicle_id: String) -> bool:
    if vehicle_id in SCRAPPED_IDS:
        return false
    return vehicle_id == DEFAULT_ID or FleetRegistry.has(vehicle_id)

static func ids(include_legacy: bool = true) -> Array:
    var result: Array = [DEFAULT_ID]
    for vehicle_id in _allowed_fleet_ids():
        if not result.has(vehicle_id):
            result.append(vehicle_id)
    return result

static func production_ids() -> Array:
    return ids(false)

static func next_id(current_id: String, include_legacy: bool = false) -> String:
    var order := ids(include_legacy)
    var current := order.find(current_id)
    return str(order[(current + 1) % order.size()]) if current >= 0 else str(order[0])
