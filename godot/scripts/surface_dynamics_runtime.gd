extends Node
class_name YardmanSurfaceDynamicsRuntime

# Weather-to-handling bridge. The vehicle solver remains data-driven: this
# service derives a temporary surface profile from the canonical dry vehicle
# profile instead of accumulating multipliers into controller state.
const Catalog = preload("res://scripts/vehicle_catalog.gd")

var _last_vehicle_id := ""
var _last_wetness := -1.0
var _last_on_road := true

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
    if vehicle_id == _last_vehicle_id and absf(wetness - _last_wetness) < 0.002 and on_road == _last_on_road:
        return
    vehicle.set("profile", adjusted_profile(vehicle_id, wetness, on_road))
    _last_vehicle_id = vehicle_id
    _last_wetness = wetness
    _last_on_road = on_road

static func adjusted_profile(vehicle_id: String, wetness: float, on_road: bool) -> Dictionary:
    var result: Dictionary = Catalog.profile(vehicle_id)
    var wet := clampf(wetness, 0.0, 1.0)
    if wet <= 0.0001:
        return result

    if on_road:
        # Wet asphalt lengthens stops and reduces the lateral envelope without
        # turning rain into ice. Power is only trimmed near launch to represent
        # traction intervention / wheelspin in the accessible arcade solver.
        result["brake_decel_mps2"] = float(result.brake_decel_mps2) * lerpf(1.0, 0.86, wet)
        result["grip_accel_mps2"] = float(result.grip_accel_mps2) * lerpf(1.0, 0.82, wet)
        result["lateral_response"] = float(result.lateral_response) * lerpf(1.0, 0.78, wet)
        result["drift_grip_assist_mps2"] = float(result.drift_grip_assist_mps2) * lerpf(1.0, 0.90, wet)
        result["drift_grip_raw_mps2"] = float(result.drift_grip_raw_mps2) * lerpf(1.0, 0.86, wet)
        result["acceleration_low_mps2"] = float(result.acceleration_low_mps2) * lerpf(1.0, 0.92, wet)
        result["yaw_cap"] = float(result.yaw_cap) * lerpf(1.0, 0.95, wet)
    else:
        # Wet grass/earth loses more usable grip than paved road and gains
        # rolling resistance. Gravel can later receive its own surface curve.
        result["offroad_brake_decel_mps2"] = float(result.offroad_brake_decel_mps2) * lerpf(1.0, 0.78, wet)
        result["offroad_grip_accel_mps2"] = float(result.offroad_grip_accel_mps2) * lerpf(1.0, 0.72, wet)
        result["offroad_lateral_response"] = float(result.offroad_lateral_response) * lerpf(1.0, 0.68, wet)
        result["offroad_drag_base"] = float(result.offroad_drag_base) * lerpf(1.0, 1.20, wet)
        result["grass_limit_mps"] = float(result.grass_limit_mps) * lerpf(1.0, 0.82, wet)
        result["acceleration_low_mps2"] = float(result.acceleration_low_mps2) * lerpf(1.0, 0.84, wet)
    return result

func runtime_snapshot() -> Dictionary:
    return {
        "vehicle_id": _last_vehicle_id,
        "wetness": maxf(_last_wetness, 0.0),
        "on_road": _last_on_road,
    }
