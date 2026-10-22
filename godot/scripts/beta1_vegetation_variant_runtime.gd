extends Node
class_name YardmanBeta1VegetationVariantRuntime

# Reuse recovered palm silhouettes without changing vegetation geography or
# batching. Each existing palm MultiMesh cell keeps its exact transforms,
# instance count and one draw batch; only the near mesh may be substituted.
const VARIANT_ASSETS := {
    "short": {"file": "road_palm_short.glb", "height_m": 9.0},
    "curved": {"file": "road_palm_curved.glb", "height_m": 13.2},
}
const INVALID_CELL := Vector2i(2147483647, 2147483647)

var _visuals: Variant
var _processed: Dictionary = {}

func _ready() -> void:
    var owner := get_parent()
    if owner != null:
        _visuals = owner.get("visuals")
    if not get_tree().node_added.is_connected(_on_node_added):
        get_tree().node_added.connect(_on_node_added)
    call_deferred("_scan_existing")

func _exit_tree() -> void:
    if get_tree() != null and get_tree().node_added.is_connected(_on_node_added):
        get_tree().node_added.disconnect(_on_node_added)

func _on_node_added(node: Node) -> void:
    if node is MultiMeshInstance3D:
        call_deferred("_try_apply_weak", weakref(node))

func _try_apply_weak(reference: WeakRef) -> void:
    var node: Variant = reference.get_ref()
    if node is MultiMeshInstance3D:
        _try_apply(node as MultiMeshInstance3D)

func _scan_existing() -> void:
    var owner := get_parent()
    if owner == null:
        return
    var stack: Array[Node] = [owner]
    while not stack.is_empty():
        var node: Node = stack.pop_back()
        if node is MultiMeshInstance3D:
            _try_apply(node as MultiMeshInstance3D)
        for child: Node in node.get_children():
            stack.append(child)

func _try_apply(instance: MultiMeshInstance3D) -> void:
    if instance == null or instance.multimesh == null or instance.multimesh.mesh == null:
        return
    var identity := instance.get_instance_id()
    if _processed.has(identity):
        return
    var cell := target_cell_from_name(instance.name)
    if cell == INVALID_CELL:
        return
    _processed[identity] = true
    var variant := variant_for_cell(cell)
    if variant == "standard":
        instance.set_meta("beta1_palm_variant", "standard")
        return
    if _visuals == null or not _visuals.has_method("_reference_plant_mesh"):
        return
    var record: Dictionary = VARIANT_ASSETS.get(variant, {})
    if record.is_empty():
        return
    var replacement: Variant = _visuals.call("_reference_plant_mesh", str(record.file), float(record.height_m))
    if not replacement is ArrayMesh:
        return
    var before_count := instance.multimesh.instance_count
    var before_visible := instance.multimesh.visible_instance_count
    instance.multimesh.mesh = replacement as ArrayMesh
    # Reassert the budget-critical fields to make the no-density/no-batch
    # contract explicit even if a future MultiMesh implementation changes.
    instance.multimesh.instance_count = before_count
    instance.multimesh.visible_instance_count = before_visible
    instance.set_meta("beta1_palm_variant", variant)
    instance.set_meta("reference_asset", str(record.file))
    instance.set_meta("source_anchor_mutation", false)
    instance.set_meta("extra_draw_calls", false)

static func target_cell_from_name(node_name: String) -> Vector2i:
    var pieces := node_name.split("_")
    # Only the near cell itself is eligible. _Distant and _Grass nodes contain
    # extra suffix pieces and deliberately remain on their existing LOD meshes.
    if pieces.size() != 4 or pieces[0] != "Plants" or pieces[3] != "palm":
        return INVALID_CELL
    if not pieces[1].is_valid_int() or not pieces[2].is_valid_int():
        return INVALID_CELL
    return Vector2i(int(pieces[1]), int(pieces[2]))

static func variant_for_cell(cell: Vector2i) -> String:
    if cell == INVALID_CELL:
        return "standard"
    var mixed := (cell.x * 73856093) ^ (cell.y * 19349663)
    var bucket := posmod(mixed, 10)
    if bucket <= 1:
        return "short"
    if bucket <= 3:
        return "curved"
    return "standard"

static func asset_contract() -> Dictionary:
    return {
        "variants": VARIANT_ASSETS.duplicate(true),
        "placement_source": "existing RoadsideProxy palm MultiMesh cells",
        "instance_count_mutation": false,
        "anchor_mutation": false,
        "extra_nodes": false,
        "extra_draw_calls": false,
        "distant_lod_mutation": false,
        "collision": false,
        "asset_absent_fallback": true,
    }
