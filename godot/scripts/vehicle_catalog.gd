extends RefCounted
class_name YardmanVehicleCatalog

const FleetRegistry = preload("res://scripts/vehicle_fleet_registry.gd")

# Map + cars recovery catalog. Crown is the owner baseline. Mark X and every
# 992 selector are intentionally excluded from runtime selection.
const DEFAULT_ID := "toyota_crown"
const PRODUCTION_IDS := ["toyota_crown"]

const VEHICLES := {
    "toyota_crown": {
        "id": "toyota_crown", "manufacturer": "Toyota", "display_name": "Toyota Crown", "drivetrain": "RWD", "hero_scene": "toyota_crown_2013.glb",
        "mass_kg": 1710.0, "wheelbase_m": 2.85, "use_visual_wheelbase": false, "track_width_m": 1.55, "cg_height_m": 0.54,
        "dimensions_m": [1.80, 1.46, 4.89], "visual_scale": [0.973, 1.123, 1.223], "wheel_radius_m": 0.34,
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
        "transmission": "8-speed automatic", "peak_torque_nm": 350.0,
        "gear_ratios": [4.71, 3.14, 2.11, 1.67, 1.28, 1.00, 0.84, 0.67], "final_drive": 3.13, "reverse_ratio": 3.32,
        "drivetrain_efficiency": 0.89, "powertrain_physics_blend": 0.46,
        "torque_curve": [[720.0, 0.56], [1600.0, 0.80], [2800.0, 0.96], [3900.0, 1.00], [5200.0, 0.92], [6600.0, 0.68]],
        "shift_up_light_rpm": 2650.0, "shift_up_rpm": 6050.0, "shift_down_rpm": 1350.0,
        "shift_time_s": 0.31, "shift_torque_factor": 0.38, "kickdown_throttle": 0.78, "launch_free_rev_fraction": 0.30, "rpm_response": 9.4,
        "gear_speed_mps": [8.5, 17.0, 28.0, 41.0, 54.0], "rpm_per_mps": [380.0, 232.0, 168.0, 126.0, 96.0, 78.0],
        "idle_rpm": 720.0, "redline_rpm": 6600.0, "throttle_rpm_boost": 470.0,
        "paint_rgb": [0.055, 0.070, 0.090], "audio_profile": "crown_v6", "camera_distance_m": 8.1,
    },
}

static func _blocked(vehicle_id: String) -> bool:
    var lowered := vehicle_id.strip_edges().to_lower()
    return lowered == "toyota_mark_x" or lowered.contains("992")

static func profile(vehicle_id: String) -> Dictionary:
    if _blocked(vehicle_id):
        push_warning("Yardman blocked retired vehicle selector: %s" % vehicle_id)
        return VEHICLES[DEFAULT_ID].duplicate(true)
    if VEHICLES.has(vehicle_id):
        return VEHICLES[vehicle_id].duplicate(true)
    if FleetRegistry.has(vehicle_id):
        var result: Dictionary = VEHICLES[DEFAULT_ID].duplicate(true)
        var recovered := FleetRegistry.entry(vehicle_id)
        for key in recovered.keys():
            result[key] = recovered[key]
        return result
    return VEHICLES[DEFAULT_ID].duplicate(true)

static func has(vehicle_id: String) -> bool:
    return not _blocked(vehicle_id) and (VEHICLES.has(vehicle_id) or FleetRegistry.has(vehicle_id))

static func ids(_include_legacy: bool = true) -> Array:
    var result: Array = PRODUCTION_IDS.duplicate()
    for vehicle_id in FleetRegistry.ids():
        var selector := str(vehicle_id)
        if not _blocked(selector) and not result.has(selector):
            result.append(selector)
    return result

static func production_ids() -> Array:
    return ids(false)

static func next_id(current_id: String, include_legacy: bool = false) -> String:
    var order := ids(include_legacy)
    if order.is_empty():
        return DEFAULT_ID
    var current := order.find(current_id)
    return str(order[(current + 1) % order.size()]) if current >= 0 else str(order[0])
