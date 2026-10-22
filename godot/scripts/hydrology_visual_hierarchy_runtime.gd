extends Node
class_name YardmanHydrologyVisualHierarchyRuntime

# V2-only visual enrichment. The hydrology renderer already owns geographic
# placement, DEM elevations, crossing clipping and mesh safety. This pass leaves
# every vertex/index unchanged and adds only a per-vertex rendering classification
# derived from the compiled ribbon geometry, then applies one shared material.

const HIERARCHY_SHADER = preload("res://shaders/river_surface_hierarchy.gdshader")
const MIN_WIDTH_M := 0.7
const MAX_WIDTH_M := 28.0
const GRADE_LOW_PERMILLE := 2.0
const GRADE_HIGH_PERMILLE := 85.0

var enriched_tiles := 0
var enriched_quads := 0
var rejected_layout := 0
var _material: ShaderMaterial

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
    for node in scene.find_children("Hydrology_*", "MeshInstance3D", true, false):
        _queue_instance(node)

func _on_node_added(node: Node) -> void:
    if node is MeshInstance3D and str(node.name).begins_with("Hydrology_"):
        _queue_instance(node)

func _queue_instance(node: MeshInstance3D) -> void:
    call_deferred("_enrich_instance", weakref(node))

func _hierarchy_material() -> ShaderMaterial:
    if _material == null:
        _material = ShaderMaterial.new()
        _material.shader = HIERARCHY_SHADER
    return _material

func _is_v2_hydrology(instance: MeshInstance3D) -> bool:
    var parent := instance.get_parent()
    if parent == null or not parent.has_method("uses_compiled_dem_elevation"):
        return false
    return bool(parent.call("uses_compiled_dem_elevation"))

static func _quad_metrics(a_left: Vector3, a_right: Vector3, b_left: Vector3, b_right: Vector3) -> Color:
    var width := a_left.distance_to(a_right)
    var start := (a_left + a_right) * 0.5
    var finish := (b_left + b_right) * 0.5
    var horizontal := Vector2(finish.x - start.x, finish.z - start.z).length()
    var grade_permille := absf(finish.y - start.y) / maxf(horizontal, 0.001) * 1000.0
    var width_factor := smoothstep(MIN_WIDTH_M, MAX_WIDTH_M, width)
    var grade_factor := smoothstep(GRADE_LOW_PERMILLE, GRADE_HIGH_PERMILLE, grade_permille)
    var rapid := clampf(grade_factor * lerpf(1.0, 0.42, width_factor), 0.0, 1.0)
    return Color(width_factor, grade_factor, rapid, 1.0)

func _enrich_instance(reference) -> bool:
    var raw = reference.get_ref() if reference is WeakRef else reference
    if raw == null or not is_instance_valid(raw) or not raw is MeshInstance3D:
        return false
    var instance := raw as MeshInstance3D
    if bool(instance.get_meta("hydrology_hierarchy_enriched", false)):
        return false
    if not _is_v2_hydrology(instance):
        return false
    var source := instance.mesh as ArrayMesh
    if source == null or source.get_surface_count() != 1:
        rejected_layout += 1
        return false
    var arrays := source.surface_get_arrays(0)
    if arrays.size() < Mesh.ARRAY_MAX:
        rejected_layout += 1
        return false
    var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
    var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
    if vertices.is_empty() or vertices.size() % 4 != 0 or indices.is_empty():
        rejected_layout += 1
        return false
    var colors := PackedColorArray()
    colors.resize(vertices.size())
    var quad_count := 0
    for base in range(0, vertices.size(), 4):
        var metadata := _quad_metrics(vertices[base], vertices[base + 1], vertices[base + 2], vertices[base + 3])
        colors[base] = metadata
        colors[base + 1] = metadata
        colors[base + 2] = metadata
        colors[base + 3] = metadata
        quad_count += 1
    arrays[Mesh.ARRAY_COLOR] = colors
    var enriched := ArrayMesh.new()
    enriched.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    enriched.surface_set_material(0, _hierarchy_material())
    instance.mesh = enriched
    instance.set_meta("hydrology_hierarchy_enriched", true)
    instance.set_meta("hydrology_hierarchy_quads", quad_count)
    enriched_tiles += 1
    enriched_quads += quad_count
    return true
