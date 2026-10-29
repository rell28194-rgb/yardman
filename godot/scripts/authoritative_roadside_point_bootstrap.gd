extends Node

const Runtime = preload("res://scripts/authoritative_roadside_point_runtime.gd")
var _attached_scene_id := 0

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    set_process(true)

func _process(_delta: float) -> void:
    var tree := get_tree()
    if tree == null:
        return
    var scene := tree.current_scene
    if scene == null:
        return
    var identity := scene.get_instance_id()
    if identity == _attached_scene_id and scene.get_node_or_null("AuthoritativeRoadsidePointRuntime") != null:
        return
    if scene.get_node_or_null("JamaicaRoadStreamer") == null or scene.get_node_or_null("JamaicaTerrainStreamer") == null:
        return
    var existing := scene.get_node_or_null("AuthoritativeRoadsidePointRuntime")
    if existing == null:
        var runtime := Runtime.new()
        runtime.name = "AuthoritativeRoadsidePointRuntime"
        scene.add_child(runtime)
    _attached_scene_id = identity
