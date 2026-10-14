extends RefCounted
class_name YardmanVehicleCatalog

# Physics/tuning data are deliberately separate from controller code so adding a
# vehicle does not fork the solver. Values are game tuning baselines, not claims
# of exact homologation specifications for a particular trim/year.
const DEFAULT_ID := "legacy_sedan"
const PRODUCTION_IDS := ["toyota_crown", "toyota_mark_x", "port_royal_992"]

const VEHICLES := {
    "legacy_sedan": {
        "id": "legacy_sedan", "manufacturer": "Yardman", "display_name": "Legacy Sedan", "drivetrain": "RWD",
        "mass_kg": 1580.0, "wheelbase_m": 2.56, "use_visual_wheelbase": true, "track_width_m": 1.44, "cg_height_m": 0.55,
        "dimensions_m": [1.85, 1.30, 4.00], "visual_scale": [1.0, 1.0, 1.0],
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
        "gear_speed_mps": [9.0, 18.0, 29.0, 42.0], "rpm_per_mps": [405.0, 245.0, 178.0, 132.0, 101.0],
        "idle_rpm": 900.0, "redline_rpm": 6900.0, "throttle_rpm_boost": 520.0,
        "paint_rgb": [0.14, 0.31, 0.37], "audio_profile": "legacy_inline6", "camera_distance_m": 7.8,
    },
    "toyota_crown": {
        "id": "toyota_crown", "manufacturer": "Toyota", "display_name": "Toyota Crown", "drivetrain": "RWD",
        "mass_kg": 1710.0, "wheelbase_m": 2.85, "use_visual_wheelbase": false, "track_width_m": 1.55, "cg_height_m": 0.54,
        "dimensions_m": [1.80, 1.46, 4.89], "visual_scale": [0.973, 1.123, 1.223],
        "max_forward_mps": 61.0, "max_reverse_mps": 7.5, "grass_limit_mps": 15.5,
        "acceleration_low_mps2": 6.7, "acceleration_high_mps2": 3.8, "reverse_accel_factor": 0.62,
        "brake_decel_mps2": 11.4, "offroad_brake_decel_mps2": 6.8,
        "steering_low_deg": 35.0, "steering_high_deg": 12.0,
        "grip_accel_mps2": 10.7, "offroad_grip_accel_mps2": 5.8, "drift_grip_assist_mps2": 9.7, "drift_grip_raw_mps2": 8.6,
        "yaw_cap": 1.24, "drift_yaw_cap": 1.43, "lateral_response": 7.8, "offroad_lateral_response": 4.5,
        "drift_lateral_cap_mps": 8.4, "drift_slip_assist": 0.32, "drift_slip_raw": 0.25, "drift_bonus_assist": 1.7, "drift_bonus_raw": 0.7,
        "rolling_drag_base": 0.095, "aero_drag": 0.00078, "offroad_drag_base": 0.76, "offroad_aero_drag": 0.0040,
        "offroad_overlimit_drag": 2.4, "offroad_overlimit_slope": 0.34,
        "suspension_ray_top_m": 1.00, "suspension_ray_length_m": 1.72,
        "gear_speed_mps": [8.5, 17.0, 28.0, 41.0, 54.0], "rpm_per_mps": [380.0, 232.0, 168.0, 126.0, 96.0, 78.0],
        "idle_rpm": 720.0, "redline_rpm": 6600.0, "throttle_rpm_boost": 470.0,
        "paint_rgb": [0.055, 0.070, 0.090], "audio_profile": "crown_v6", "camera_distance_m": 8.1,
    },
    "toyota_mark_x": {
        "id": "toyota_mark_x", "manufacturer": "Toyota", "display_name": "Toyota Mark X", "drivetrain": "RWD",
        "mass_kg": 1540.0, "wheelbase_m": 2.85, "use_visual_wheelbase": false, "track_width_m": 1.54, "cg_height_m": 0.51,
        "dimensions_m": [1.79, 1.44, 4.77], "visual_scale": [0.968, 1.108, 1.193],
        "max_forward_mps": 66.0, "max_reverse_mps": 8.0, "grass_limit_mps": 16.0,
        "acceleration_low_mps2": 7.4, "acceleration_high_mps2": 4.2, "reverse_accel_factor": 0.64,
        "brake_decel_mps2": 12.2, "offroad_brake_decel_mps2": 7.0,
        "steering_low_deg": 37.0, "steering_high_deg": 12.5,
        "grip_accel_mps2": 11.8, "offroad_grip_accel_mps2": 6.0, "drift_grip_assist_mps2": 10.2, "drift_grip_raw_mps2": 8.9,
        "yaw_cap": 1.37, "drift_yaw_cap": 1.58, "lateral_response": 7.4, "offroad_lateral_response": 4.6,
        "drift_lateral_cap_mps": 9.2, "drift_slip_assist": 0.37, "drift_slip_raw": 0.29, "drift_bonus_assist": 2.0, "drift_bonus_raw": 0.85,
        "rolling_drag_base": 0.088, "aero_drag": 0.00070, "offroad_drag_base": 0.72, "offroad_aero_drag": 0.0039,
        "offroad_overlimit_drag": 2.3, "offroad_overlimit_slope": 0.33,
        "suspension_ray_top_m": 0.96, "suspension_ray_length_m": 1.66,
        "gear_speed_mps": [9.0, 18.5, 30.0, 44.0, 57.0], "rpm_per_mps": [410.0, 250.0, 180.0, 134.0, 103.0, 83.0],
        "idle_rpm": 760.0, "redline_rpm": 7000.0, "throttle_rpm_boost": 540.0,
        "paint_rgb": [0.20, 0.035, 0.035], "audio_profile": "mark_x_v6", "camera_distance_m": 7.9,
    },
    "port_royal_992": {
        "id": "port_royal_992", "manufacturer": "Yardman", "display_name": "Port Royal 992", "drivetrain": "RWD",
        "mass_kg": 1515.0, "wheelbase_m": 2.45, "use_visual_wheelbase": false, "track_width_m": 1.62, "cg_height_m": 0.43,
        "dimensions_m": [1.85, 1.30, 4.54], "visual_scale": [1.0, 1.0, 1.135],
        "max_forward_mps": 82.0, "max_reverse_mps": 9.0, "grass_limit_mps": 14.5,
        "acceleration_low_mps2": 9.6, "acceleration_high_mps2": 5.0, "reverse_accel_factor": 0.58,
        "brake_decel_mps2": 14.2, "offroad_brake_decel_mps2": 7.4,
        "steering_low_deg": 33.0, "steering_high_deg": 10.5,
        "grip_accel_mps2": 13.8, "offroad_grip_accel_mps2": 5.6, "drift_grip_assist_mps2": 11.7, "drift_grip_raw_mps2": 9.8,
        "yaw_cap": 1.46, "drift_yaw_cap": 1.68, "lateral_response": 8.8, "offroad_lateral_response": 4.2,
        "drift_lateral_cap_mps": 10.0, "drift_slip_assist": 0.34, "drift_slip_raw": 0.27, "drift_bonus_assist": 2.0, "drift_bonus_raw": 0.8,
        "rolling_drag_base": 0.080, "aero_drag": 0.00058, "offroad_drag_base": 0.82, "offroad_aero_drag": 0.0044,
        "offroad_overlimit_drag": 2.7, "offroad_overlimit_slope": 0.39,
        "suspension_ray_top_m": 0.87, "suspension_ray_length_m": 1.50,
        "gear_speed_mps": [10.0, 21.0, 34.0, 49.0, 65.0], "rpm_per_mps": [430.0, 270.0, 196.0, 148.0, 116.0, 92.0],
        "idle_rpm": 820.0, "redline_rpm": 7600.0, "throttle_rpm_boost": 620.0,
        "paint_rgb": [0.72, 0.12, 0.055], "audio_profile": "port_royal_flat6", "camera_distance_m": 7.2,
    },
}

static func profile(vehicle_id: String) -> Dictionary:
    var key := vehicle_id if VEHICLES.has(vehicle_id) else DEFAULT_ID
    return VEHICLES[key].duplicate(true)

static func has(vehicle_id: String) -> bool:
    return VEHICLES.has(vehicle_id)

static func ids(include_legacy: bool = true) -> Array:
    var result: Array = []
    if include_legacy:
        result.append(DEFAULT_ID)
    result.append_array(PRODUCTION_IDS)
    return result

static func production_ids() -> Array:
    return PRODUCTION_IDS.duplicate()

static func next_id(current_id: String, include_legacy: bool = false) -> String:
    var order := ids(include_legacy)
    var current := order.find(current_id)
    return str(order[(current + 1) % order.size()]) if current >= 0 else str(order[0])
