extends Node
class_name YardmanCrownMaterialPresentationRuntime

# Exact-name pass for the accepted Crown GLB. It preserves source colors,
# textures and material identity; only physically meaningful presentation
# parameters are refined. Generic/fallback/fleet materials are left untouched.
const TARGETS := {
    "crownpaint": "paint",
    "crownglass": "glass",
    "crownsilver": "silver",
    "crownwheelmetal": "wheel",
}

var _last_visual_id := 0
var _last_stats: Dictionary = {}

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS

func _process(_delta: float) -> void:
    var tree := get_tree()
    if tree == null:
        return
    var scene := tree.current_scene
    if scene == null:
        return
    var controller = scene.get("vehicle")
    if controller == null:
        return
    var visual = controller.get("visual")
    if not visual is Node3D or visual.get("is_reference_model") != true:
        return
    var identity := (visual as Node3D).get_instance_id()
    if identity == _last_visual_id:
        return
    _last_stats = polish_visual(visual as Node3D)
    _last_visual_id = identity

static func polish_visual(root: Node3D) -> Dictionary:
    var stats := {
        "paint": 0,
        "glass": 0,
        "silver": 0,
        "wheel": 0,
        "textures_preserved": true,
        "generic_materials_touched": 0,
    }
    if root == null:
        return stats
    var clones: Dictionary = {}
    var meshes: Array[MeshInstance3D] = []
    if root is MeshInstance3D:
        meshes.append(root as MeshInstance3D)
    for raw: Node in root.find_children("*", "MeshInstance3D", true, false):
        meshes.append(raw as MeshInstance3D)
    for instance: MeshInstance3D in meshes:
        if instance.mesh == null:
            continue
        for surface_index in range(instance.mesh.get_surface_count()):
            var source := instance.get_active_material(surface_index) as StandardMaterial3D
            if source == null:
                continue
            var kind := str(TARGETS.get(source.resource_name.to_lower(), ""))
            if kind.is_empty():
                continue
            var key := "%d:%s" % [source.get_instance_id(), kind]
            var material := clones.get(key) as StandardMaterial3D
            if material == null:
                material = _polished_clone(source, kind)
                clones[key] = material
            instance.set_surface_override_material(surface_index, material)
            stats[kind] = int(stats.get(kind, 0)) + 1
    root.set_meta("yardman_crown_material_presentation", stats.duplicate(true))
    return stats

static func _polished_clone(source: StandardMaterial3D, kind: String) -> StandardMaterial3D:
    var material := source.duplicate() as StandardMaterial3D
    material.resource_local_to_scene = true
    material.resource_name = source.resource_name
    match kind:
        "paint":
            # Source Crown paint is dielectric and already authored near 0.122
            # roughness. Clearcoat adds the missing outer lacquer response
            # without turning the body into metallic paint.
            material.metallic = source.metallic
            material.roughness = clampf(source.roughness * 0.90, 0.085, 0.13)
            material.clearcoat_enabled = true
            material.clearcoat_roughness = 0.075
        "glass":
            material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
            material.cull_mode = BaseMaterial3D.CULL_DISABLED
            material.metallic = minf(source.metallic, 0.08)
            material.roughness = clampf(source.roughness * 0.78, 0.045, 0.065)
            material.albedo_color.a = source.albedo_color.a
        "silver":
            material.metallic = maxf(source.metallic, 0.90)
            material.roughness = clampf(source.roughness, 0.18, 0.24)
        "wheel":
            # Keep the accepted wheel color and texture, but give the alloy a
            # clear enough conductor target that float storage cannot land on
            # the test/quality boundary.
            material.metallic = maxf(source.metallic, 0.90)
            material.roughness = clampf(source.roughness, 0.20, 0.27)
    return material

func debug_snapshot() -> Dictionary:
    return _last_stats.duplicate(true)
