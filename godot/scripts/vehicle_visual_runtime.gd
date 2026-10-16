extends Node

const Catalog = preload("res://scripts/vehicle_catalog.gd")
const Styler = preload("res://scripts/vehicle_visual_styler.gd")
const ProfileGeometry = preload("res://scripts/vehicle_profile_geometry.gd")
const Stance = preload("res://scripts/vehicle_stance_runtime.gd")

var _last_world_visual_id := 0
var _last_world_vehicle_id := ""
var _last_preview_visual_id := 0
var _last_preview_vehicle_id := ""
var _last_world_stats: Dictionary = {}
var _last_preview_stats: Dictionary = {}

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS

func _process(_delta: float) -> void:
    _style_world_vehicle()
    _style_garage_preview()

func style_visual(visual: Node3D, vehicle_id: String) -> Dictionary:
    if visual == null or not Catalog.has(vehicle_id):
        return {}
    var profile := Catalog.profile(vehicle_id)
    var stance_stats := Stance.apply(visual, profile)
    var geometry_stats := ProfileGeometry.apply(visual, profile)
    var stats := Styler.apply(visual, profile)
    stats["geometry_identity"] = str(geometry_stats.get("vehicle_id", vehicle_id))
    stats["geometry_signature"] = str(geometry_stats.get("signature", ""))
    stats["profile_geometry"] = bool(geometry_stats.get("profile_geometry", false))
    stats["dedicated_mesh"] = bool(geometry_stats.get("dedicated_mesh", false))
    stats["geometry_mesh_parts"] = int(geometry_stats.get("mesh_parts", 0))
    stats["hidden_shared_meshes"] = int(geometry_stats.get("hidden_shared_meshes", 0))
    stats["stance_wheels"] = int(stance_stats.get("wheels_positioned", 0))
    stats["source_stance_preserved"] = bool(stance_stats.get("dedicated_mesh", false))
    stats["stance_wheelbase_m"] = float(stance_stats.get("wheelbase_world_m", 0.0))
    stats["stance_track_m"] = float(stance_stats.get("track_world_m", 0.0))
    stats["stance_radius_m"] = float(stance_stats.get("radius_world_m", 0.0))
    return stats

func _style_world_vehicle() -> void:
    var scene := get_tree().current_scene
    if scene == null:
        return
    var controller = scene.get("vehicle")
    if controller == null:
        return
    var visual = controller.get("visual")
    if not visual is Node3D:
        return
    var vehicle_id := str(controller.get("vehicle_id"))
    if not Catalog.has(vehicle_id):
        return
    var instance_id := (visual as Node3D).get_instance_id()
    if instance_id == _last_world_visual_id and vehicle_id == _last_world_vehicle_id:
        return
    _last_world_stats = style_visual(visual as Node3D, vehicle_id)
    _last_world_visual_id = instance_id
    _last_world_vehicle_id = vehicle_id

func _style_garage_preview() -> void:
    var garage := get_node_or_null("/root/VehicleGarage")
    if garage == null:
        return
    var preview = garage.get("_preview_model")
    var selector = garage.get("_selector")
    if not preview is Node3D or not selector is OptionButton:
        return
    var option := selector as OptionButton
    if option.item_count == 0 or option.selected < 0:
        return
    var vehicle_id := str(option.get_item_metadata(option.selected))
    if not Catalog.has(vehicle_id):
        return
    var instance_id := (preview as Node3D).get_instance_id()
    if instance_id == _last_preview_visual_id and vehicle_id == _last_preview_vehicle_id:
        return
    _last_preview_stats = style_visual(preview as Node3D, vehicle_id)
    _last_preview_visual_id = instance_id
    _last_preview_vehicle_id = vehicle_id

func debug_snapshot() -> Dictionary:
    return {
        "world_vehicle": _last_world_vehicle_id,
        "preview_vehicle": _last_preview_vehicle_id,
        "world_stats": _last_world_stats.duplicate(true),
        "preview_stats": _last_preview_stats.duplicate(true),
    }
