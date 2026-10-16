extends Node
class_name YardmanVehicleCameraRuntime

const Catalog = preload("res://scripts/vehicle_catalog.gd")

# Per-car chase presentation stays outside the physics solver. Distance comes
# from the shared catalog; height/FOV/response tune the camera to each body type.
const CAMERA_STYLE := {
    "legacy_sedan": {"height_m": 1.50, "vertical_m": 1.40, "fov_base": 78.0, "fov_gain": 7.0, "follow_response": 9.0},
    "toyota_crown": {"height_m": 1.58, "vertical_m": 1.48, "fov_base": 76.5, "fov_gain": 6.0, "follow_response": 8.2},
    "toyota_mark_x": {"height_m": 1.52, "vertical_m": 1.42, "fov_base": 78.0, "fov_gain": 6.8, "follow_response": 9.2},
    "port_royal_992": {"height_m": 1.36, "vertical_m": 1.25, "fov_base": 79.5, "fov_gain": 8.5, "follow_response": 11.5},
}

var _last_vehicle_id := ""
var _last_distance := 0.0
var _last_fov := 0.0

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    # Main updates its baseline chase camera at priority 0. This pass runs after
    # it and applies the selected vehicle's authored presentation profile.
    process_priority = 40

func _physics_process(delta: float) -> void:
    var scene := get_tree().current_scene
    if scene == null:
        return
    var player = scene.get("player")
    if player == null or not bool(player.get("in_vehicle")):
        return
    var camera = scene.get("camera")
    var car = scene.get("car")
    var vehicle = scene.get("vehicle")
    if not camera is Camera3D or not car is CharacterBody3D or vehicle == null:
        return

    var vehicle_id := str(vehicle.get("vehicle_id"))
    var style := exterior_profile(vehicle_id)
    var yaw_value = scene.get("camera_yaw")
    var pitch_value = scene.get("camera_pitch")
    if not (yaw_value is float or yaw_value is int) or not (pitch_value is float or pitch_value is int):
        return
    var yaw := float(yaw_value)
    var pitch := float(pitch_value)
    var distance := float(style.distance_m)
    var pivot := (car as CharacterBody3D).position + Vector3.UP * float(style.height_m)
    var offset := Vector3(0.0, -sin(pitch) * distance + float(style.vertical_m), cos(pitch) * distance).rotated(Vector3.UP, yaw)
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
            var direction := (pivot - desired).normalized()
            desired = (hit.position as Vector3) + direction * 0.30

    var speed := absf(float(vehicle.get("speed_mps")))
    var reduced_motion := false
    var touch = scene.get("touch")
    if touch != null:
        var settings = touch.get("settings")
        if settings is Dictionary:
            reduced_motion = bool(settings.get("reduced_motion", false))
    var desired_fov := target_fov(vehicle_id, speed, reduced_motion)
    var response := 1.0 - exp(-maxf(delta, 0.0) * float(style.follow_response))
    (camera as Camera3D).position = (camera as Camera3D).position.lerp(desired, response)
    (camera as Camera3D).fov = lerpf((camera as Camera3D).fov, desired_fov, clampf(response * 0.62, 0.0, 1.0))

    _last_vehicle_id = vehicle_id
    _last_distance = distance
    _last_fov = desired_fov

static func exterior_profile(vehicle_id: String) -> Dictionary:
    var profile := Catalog.profile(vehicle_id)
    var style: Dictionary = CAMERA_STYLE.get(str(profile.id), CAMERA_STYLE.legacy_sedan).duplicate(true)
    style["vehicle_id"] = str(profile.id)
    style["distance_m"] = float(profile.get("camera_distance_m", 7.8))
    return style

static func target_fov(vehicle_id: String, speed_mps: float, reduced_motion: bool = false) -> float:
    var style := exterior_profile(vehicle_id)
    var base := float(style.fov_base)
    if reduced_motion:
        return base
    return base + float(style.fov_gain) * clampf(absf(speed_mps) / 60.0, 0.0, 1.0)

func runtime_snapshot() -> Dictionary:
    return {"vehicle_id": _last_vehicle_id, "distance_m": _last_distance, "target_fov": _last_fov}
