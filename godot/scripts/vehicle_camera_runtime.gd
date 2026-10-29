extends Node
class_name YardmanVehicleCameraRuntime

# Presentation only. Vehicle physics remain authoritative in vehicle_controller.gd.
# This pass runs after the main scene camera update and gives different body
# classes an appropriate chase distance, pivot height and speed-sensitive FOV.
const DEFAULT_STYLE := {
    "distance_m": 7.8,
    "pivot_height_m": 1.50,
    "vertical_m": 1.40,
    "fov_base": 78.0,
    "fov_gain": 7.0,
    "follow_response": 8.5,
}

var _last_vehicle_id := ""
var _last_style := "default"
var _last_target_fov := 78.0

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    process_priority = 40

func _physics_process(delta: float) -> void:
    var tree := get_tree()
    if tree == null:
        return
    var scene := tree.current_scene
    if scene == null:
        return
    var player = scene.get("player")
    if player == null or player.get("in_vehicle") != true:
        return
    var camera = scene.get("camera")
    var car = scene.get("car")
    var vehicle = scene.get("vehicle")
    if not camera is Camera3D or not car is CharacterBody3D or vehicle == null:
        return

    var yaw_value = scene.get("camera_yaw")
    var pitch_value = scene.get("camera_pitch")
    if not (yaw_value is float or yaw_value is int) or not (pitch_value is float or pitch_value is int):
        return

    var vehicle_id := str(vehicle.get("vehicle_id"))
    var profile := profile_for(vehicle_id)
    var yaw := float(yaw_value)
    var pitch := float(pitch_value)
    var distance := float(profile.distance_m)
    var pivot := (car as CharacterBody3D).position + Vector3.UP * float(profile.pivot_height_m)
    var offset := Vector3(
        0.0,
        -sin(pitch) * distance + float(profile.vertical_m),
        cos(pitch) * distance
    ).rotated(Vector3.UP, yaw)
    var desired := pivot + offset

    var world := (car as CharacterBody3D).get_world_3d()
    if world != null:
        var query := PhysicsRayQueryParameters3D.create(pivot, desired, 1)
        var excluded: Array[RID] = [(car as CharacterBody3D).get_rid()]
        if player is CollisionObject3D:
            excluded.append((player as CollisionObject3D).get_rid())
        query.exclude = excluded
        query.collide_with_areas = false
        var hit := world.direct_space_state.intersect_ray(query)
        if not hit.is_empty():
            desired = (hit.position as Vector3) + (hit.normal as Vector3) * 0.30

    var reduced_motion := false
    var touch = scene.get("touch")
    if touch != null:
        var settings = touch.get("settings")
        if settings is Dictionary:
            reduced_motion = settings.get("reduced_motion", false) == true

    var speed := absf(float(vehicle.get("speed_mps")))
    var desired_fov := target_fov(profile, speed, reduced_motion)
    var safe_delta := clampf(delta, 0.0, 0.25) if is_finite(delta) else 0.016
    var response := 1.0 - exp(-safe_delta * float(profile.follow_response))
    (camera as Camera3D).position = (camera as Camera3D).position.lerp(desired, response)
    (camera as Camera3D).fov = lerpf((camera as Camera3D).fov, desired_fov, clampf(response * 0.68, 0.0, 1.0))
    if (camera as Camera3D).position.distance_squared_to(pivot) > 0.01:
        (camera as Camera3D).look_at(pivot, Vector3.UP)

    _last_vehicle_id = vehicle_id
    _last_style = str(profile.style)
    _last_target_fov = desired_fov

static func profile_for(vehicle_id: String) -> Dictionary:
    var id := vehicle_id.to_lower()
    var style: Dictionary = DEFAULT_STYLE.duplicate(true)
    style["style"] = "default"

    if id == "toyota_crown":
        style.merge({
            "distance_m": 7.45,
            "pivot_height_m": 1.58,
            "vertical_m": 1.46,
            "fov_base": 76.5,
            "fov_gain": 6.0,
            "follow_response": 8.4,
            "style": "crown_sedan",
        }, true)
    elif "peterbilt" in id or "truck" in id or "van" in id:
        style.merge({
            "distance_m": 10.6,
            "pivot_height_m": 2.55,
            "vertical_m": 2.25,
            "fov_base": 74.0,
            "fov_gain": 5.0,
            "follow_response": 6.4,
            "style": "large_body",
        }, true)
    elif _is_low_sports_car(id):
        style.merge({
            "distance_m": 6.75,
            "pivot_height_m": 1.26,
            "vertical_m": 1.18,
            "fov_base": 78.5,
            "fov_gain": 8.2,
            "follow_response": 10.5,
            "style": "low_sports",
        }, true)
    elif _is_compact_or_drift_car(id):
        style.merge({
            "distance_m": 7.05,
            "pivot_height_m": 1.40,
            "vertical_m": 1.30,
            "fov_base": 78.0,
            "fov_gain": 7.4,
            "follow_response": 9.6,
            "style": "compact_drift",
        }, true)
    return style

static func target_fov(profile: Dictionary, speed_mps: float, reduced_motion: bool = false) -> float:
    var base := float(profile.get("fov_base", 78.0))
    if reduced_motion:
        return base
    var gain := float(profile.get("fov_gain", 7.0))
    return base + gain * clampf(absf(speed_mps) / 52.0, 0.0, 1.0)

static func _is_low_sports_car(id: String) -> bool:
    for token in ["r8", "lfa", "s2000", "rx7", "mx5", "350z", "viper", "supra", "skyline", "camaro", "s30z", "nsx", "solstice"]:
        if token in id:
            return true
    return false

static func _is_compact_or_drift_car(id: String) -> bool:
    for token in ["ae86", "civic", "180sx", "evo", "wrx", "m3_e30", "m3_e36", "drift", "vaz"]:
        if token in id:
            return true
    return false

func debug_snapshot() -> Dictionary:
    return {
        "vehicle_id": _last_vehicle_id,
        "style": _last_style,
        "target_fov": _last_target_fov,
    }
