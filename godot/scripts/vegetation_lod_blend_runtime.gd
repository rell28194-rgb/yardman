extends Node
class_name YardmanVegetationLodBlendRuntime

# The existing roadside system already creates stable near/far MultiMesh pairs.
# This runtime changes only range behavior: near geometry fades out while the
# matching distant proxy fades in around the same boundary. No extra plants,
# transforms, collision, or draw batches are created.

const TREE_MARGIN_M := 52.0
const SHRUB_MARGIN_M := 30.0
const GRASS_MARGIN_M := 24.0
const DISTANT_END_MARGIN_M := 85.0

var configured_near := 0
var configured_distant := 0
var configured_grass := 0

func _ready() -> void:
    var tree := get_tree()
    if tree != null and not tree.node_added.is_connected(_on_node_added):
        tree.node_added.connect(_on_node_added)
    call_deferred("_scan_existing")

func _exit_tree() -> void:
    var tree := get_tree()
    if tree != null and tree.node_added.is_connected(_on_node_added):
        tree.node_added.disconnect(_on_node_added)

func _scan_existing() -> void:
    var scene := get_tree().current_scene if get_tree() != null else null
    if scene == null:
        return
    for node in scene.find_children("*", "MultiMeshInstance3D", true, false):
        _queue_instance(node)

func _on_node_added(node: Node) -> void:
    if node is MultiMeshInstance3D:
        _queue_instance(node)

func _queue_instance(node: MultiMeshInstance3D) -> void:
    call_deferred("_configure_instance", weakref(node))

func _is_roadside(instance: MultiMeshInstance3D) -> bool:
    var parent := instance.get_parent()
    return parent != null and str(parent.name) == "RoadsideProxy"

func _configure_instance(reference) -> bool:
    var raw = reference.get_ref() if reference is WeakRef else reference
    if raw == null or not is_instance_valid(raw) or not raw is MultiMeshInstance3D:
        return false
    var instance := raw as MultiMeshInstance3D
    if not _is_roadside(instance):
        return false
    if bool(instance.get_meta("lod_blend_configured", false)):
        return false

    var grass := bool(instance.get_meta("grass", false))
    var distant := bool(instance.get_meta("distant", false))
    instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
    if grass:
        instance.visibility_range_end_margin = minf(GRASS_MARGIN_M, maxf(4.0, instance.visibility_range_end * 0.28))
        configured_grass += 1
    elif distant:
        var boundary := instance.visibility_range_begin
        var margin := SHRUB_MARGIN_M if boundary <= 120.0 else TREE_MARGIN_M
        instance.visibility_range_begin_margin = minf(margin, maxf(6.0, boundary * 0.42))
        instance.visibility_range_end_margin = minf(DISTANT_END_MARGIN_M, maxf(12.0, instance.visibility_range_end * 0.12))
        configured_distant += 1
    else:
        var boundary := instance.visibility_range_end
        var margin := SHRUB_MARGIN_M if boundary <= 120.0 else TREE_MARGIN_M
        instance.visibility_range_end_margin = minf(margin, maxf(6.0, boundary * 0.42))
        configured_near += 1

    instance.set_meta("lod_blend_configured", true)
    return true
