extends Node

const Catalog = preload("res://scripts/vehicle_catalog.gd")
const Styler = preload("res://scripts/vehicle_visual_styler.gd")

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
    return Styler.apply(visual, Catalog.profile(vehicle_id))

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
