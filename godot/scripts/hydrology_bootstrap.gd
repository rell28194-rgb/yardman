extends Node

const HydrologyGeometryScript = preload("res://scripts/hydrology_geometry.gd")
const RoadEarthworkGeometryScript = preload("res://scripts/road_earthwork_geometry.gd")
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
    if scene.get_node_or_null("HydrologyGeometry") == null:
        var hydrology_helper = HydrologyGeometryScript.new()
        hydrology_helper.name = "HydrologyGeometry"
        scene.add_child(hydrology_helper)
    if scene.get_node_or_null("RoadEarthworkGeometry") == null:
        var earthwork_helper = RoadEarthworkGeometryScript.new()
        earthwork_helper.name = "RoadEarthworkGeometry"
        scene.add_child(earthwork_helper)
    _installed = true
