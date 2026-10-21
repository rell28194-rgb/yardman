extends Node
class_name YardmanSurfaceContentBridge

func _ready() -> void:
    get_tree().node_added.connect(_on_node_added)

func _on_node_added(node: Node) -> void:
    if not node is MeshInstance3D:
        return
    var surface_content := get_node_or_null("/root/SurfaceContent")
    if surface_content == null or not surface_content.has_method("get_state"):
        return
    if str(surface_content.call("get_state")) != "installed":
        return
    # Defer one frame so builders that add a node before assigning its final
    # material cannot race the optional content layer.
    surface_content.call_deferred("_apply_node_materials", node)
