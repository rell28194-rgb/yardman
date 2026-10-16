extends Node
class_name YardmanReflectionBudgetRuntime

var _budget := 0
var _renderer := "gles"
var _probe: ReflectionProbe
var _last_capture_position := Vector3(INF, INF, INF)
var _captures := 0

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    add_to_group("yardman_render_quality")

func apply_render_policy(active: Dictionary) -> void:
    _budget = clampi(int(active.get("reflection_budget", 0)), 0, 4)
    _renderer = str(active.get("renderer", "gles"))
    var profile := profile_for(_budget, _renderer)
    if not bool(profile.enabled):
        if _probe != null and is_instance_valid(_probe):
            _probe.visible = false
        return
    _ensure_probe()
    if _probe == null:
        return
    _probe.visible = true
    _probe.size = Vector3(float(profile.extent_m), float(profile.height_m), float(profile.extent_m))
    _probe.max_distance = float(profile.max_distance_m)
    _probe.intensity = float(profile.intensity)
    _probe.mesh_lod_threshold = float(profile.mesh_lod_threshold)
    _probe.enable_shadows = false
    _probe.update_mode = ReflectionProbe.UPDATE_ONCE

func _process(_delta: float) -> void:
    if _budget <= 0 or _renderer != "vulkan_mobile":
        return
    var scene := get_tree().current_scene
    if scene == null:
        return
    var car = scene.get("car")
    if not car is Node3D:
        return
    _ensure_probe()
    if _probe == null or not _probe.visible:
        return
    var profile := profile_for(_budget, _renderer)
    var target := (car as Node3D).global_position + Vector3.UP * float(profile.origin_height_m)
    if _last_capture_position.x == INF or target.distance_to(_last_capture_position) >= float(profile.recapture_m):
        _probe.global_position = target
        _last_capture_position = target
        _captures += 1

func _ensure_probe() -> void:
    if _renderer != "vulkan_mobile" or _budget <= 0:
        return
    if _probe != null and is_instance_valid(_probe):
        return
    var scene := get_tree().current_scene
    if scene == null:
        return
    _probe = ReflectionProbe.new()
    _probe.name = "VehicleReflectionProbe"
    _probe.box_projection = false
    _probe.enable_shadows = false
    _probe.update_mode = ReflectionProbe.UPDATE_ONCE
    scene.add_child(_probe)
    _last_capture_position = Vector3(INF, INF, INF)

static func profile_for(budget: int, renderer: String) -> Dictionary:
    var level := clampi(budget, 0, 4)
    if renderer != "vulkan_mobile" or level <= 0:
        return {"enabled": false, "recapture_m": INF, "extent_m": 0.0, "height_m": 0.0, "max_distance_m": 0.0, "intensity": 0.0, "mesh_lod_threshold": 4.0, "origin_height_m": 0.0}
    var recapture: float = float([0.0, 14.0, 9.0, 5.5, 3.5][level])
    var extent: float = float([0.0, 16.0, 22.0, 28.0, 34.0][level])
    var height: float = float([0.0, 9.0, 11.0, 13.0, 15.0][level])
    var max_distance: float = float([0.0, 24.0, 34.0, 44.0, 54.0][level])
    var intensity: float = float([0.0, 0.68, 0.78, 0.88, 0.96][level])
    var lod_threshold: float = float([4.0, 2.8, 2.3, 1.9, 1.6][level])
    return {
        "enabled": true,
        "recapture_m": recapture,
        "extent_m": extent,
        "height_m": height,
        "max_distance_m": max_distance,
        "intensity": intensity,
        "mesh_lod_threshold": lod_threshold,
        "origin_height_m": 1.35,
    }

func runtime_snapshot() -> Dictionary:
    return {"budget": _budget, "renderer": _renderer, "captures": _captures, "probe_active": _probe != null and is_instance_valid(_probe) and _probe.visible}
