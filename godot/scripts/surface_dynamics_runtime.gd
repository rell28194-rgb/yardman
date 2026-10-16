extends Node
class_name YardmanSurfaceDynamicsRuntime

# Weather-to-handling bridge. The vehicle solver remains data-driven: this
# service derives a temporary surface profile from the canonical dry vehicle
# profile instead of accumulating multipliers into controller state.
const Catalog = preload("res://scripts/vehicle_catalog.gd")

var _last_vehicle_id := ""
var _last_wetness := -1.0
var _last_on_road := true
var _last_speed_mps := -1.0

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    process_priority = -40

func _physics_process(_delta: float) -> void:
    var scene := get_tree().current_scene
    if scene == null:
        return
    var vehicle = scene.get("vehicle")
    if vehicle == null:
        return
    var atmosphere := get_node_or_null("/root/AtmosphereFX")
    var wetness := 0.0
    if atmosphere != null:
        var value = atmosphere.get("wetness")
        if value is float or value is int:
            wetness = clampf(float(value), 0.0, 1.0)
    var vehicle_id := str(vehicle.get("vehicle_id"))
    var on_road := bool(vehicle.get("on_road"))
    var speed_value = vehicle.get("speed_mps")
    var speed_mps := absf(float(speed_value)) if speed_value is float or speed_value is int else 0.0
    if vehicle_id == _last_vehicle_id \
            and absf(wetness - _last_wetness) < 0.002 \
            and on_road == _last_on_road \
            and absf(speed_mps - _last_speed_mps) < 0.75:
        return
    vehicle.set("profile", adjusted_profile(vehicle_id, wetness, on_road, speed_mps))
    _last_vehicle_id = vehicle_id
    _last_wetness = wetness
    _last_on_road = on_road
    _last_speed_mps = speed_mps

static func adjusted_profile(vehicle_id: String, wetness: float, on_road: bool, speed_mps: float = 0.0) -> Dictionary:
    var result: Dictionary = Catalog.profile(vehicle_id)
    var wet := clampf(wetness, 0.0, 1.0)
    if wet <= 0.0001:
        return result

    var speed := maxf(absf(speed_mps), 0.0)
    var high_speed_exposure := smoothstep(18.0, 46.0, speed)
    var water_load := wet * high_speed_exposure

    if on_road:
        # Wet asphalt lengthens stops and reduces the lateral envelope without
        # turning rain into ice. At motorway speeds the same standing film has a
        # larger effect, so lateral authority and braking reserve taper further.
        # Governed top speed remains unchanged; the driver can still reach it,
        # but doing so in heavy rain carries an intentionally smaller grip margin.
        result["brake_decel_mps2"] = float(result.brake_decel_mps2) * lerpf(1.0, 0.86, wet) * lerpf(1.0, 0.90, water_load)
        result["grip_accel_mps2"] = float(result.grip_accel_mps2) * lerpf(1.0, 0.82, wet) * lerpf(1.0, 0.86, water_load)
        result["lateral_response"] = float(result.lateral_response) * lerpf(1.0, 0.78, wet) * lerpf(1.0, 0.80, water_load)
        result["drift_grip_assist_mps2"] = float(result.drift_grip_assist_mps2) * lerpf(1.0, 0.90, wet) * lerpf(1.0, 0.92, water_load)
        result["drift_grip_raw_mps2"] = float(result.drift_grip_raw_mps2) * lerpf(1.0, 0.86, wet) * lerpf(1.0, 0.90, water_load)
        result["acceleration_low_mps2"] = float(result.acceleration_low_mps2) * lerpf(1.0, 0.92, wet)
        result["yaw_cap"] = float(result.yaw_cap) * lerpf(1.0, 0.95, wet) * lerpf(1.0, 0.90, water_load)
    else:
        # Wet grass/earth loses more usable grip than paved road and gains
        # rolling resistance. Higher speed compounds the instability instead of
        # teleporting the vehicle down to a new speed cap.
        result["offroad_brake_decel_mps2"] = float(result.offroad_brake_decel_mps2) * lerpf(1.0, 0.78, wet) * lerpf(1.0, 0.90, water_load)
        result["offroad_grip_accel_mps2"] = float(result.offroad_grip_accel_mps2) * lerpf(1.0, 0.72, wet) * lerpf(1.0, 0.82, water_load)
        result["offroad_lateral_response"] = float(result.offroad_lateral_response) * lerpf(1.0, 0.68, wet) * lerpf(1.0, 0.78, water_load)
        result["offroad_drag_base"] = float(result.offroad_drag_base) * lerpf(1.0, 1.20, wet) * lerpf(1.0, 1.12, water_load)
        result["grass_limit_mps"] = float(result.grass_limit_mps) * lerpf(1.0, 0.82, wet)
        result["acceleration_low_mps2"] = float(result.acceleration_low_mps2) * lerpf(1.0, 0.84, wet)
    return result

func runtime_snapshot() -> Dictionary:
    return {
        "vehicle_id": _last_vehicle_id,
        "wetness": maxf(_last_wetness, 0.0),
        "on_road": _last_on_road,
        "speed_mps": maxf(_last_speed_mps, 0.0),
    }
