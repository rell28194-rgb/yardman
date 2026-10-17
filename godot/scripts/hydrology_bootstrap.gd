extends Node

const HydrologyGeometryScript = preload("res://scripts/hydrology_geometry.gd")
var _installed := false

func _ready() -> void:
    call_deferred("_install")

func _install() -> void:
    if _installed:
        return
    var scene := get_tree().current_scene
    if scene == null:
        await get_tree().process_frame
        call_deferred("_install")
        return
    var terrain := scene.get_node_or_null("JamaicaTerrainStreamer")
    if terrain == null:
        await get_tree().process_frame
        call_deferred("_install")
        return
    if scene.get_node_or_null("HydrologyGeometry") != null:
        _installed = true
        return
    var helper = HydrologyGeometryScript.new()
    helper.name = "HydrologyGeometry"
    scene.add_child(helper)
    _installed = true
