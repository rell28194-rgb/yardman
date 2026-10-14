extends Node

# Android-only runtime bridge for Yardman's renderer policy. Desktop/headless
# validation remains Compatibility and is intentionally not dynamically scaled.
const ManagerScript = preload("res://scripts/render_quality_manager.gd")
const MaterialRegistry = preload("res://scripts/render_material_registry.gd")

var manager = ManagerScript.new()
var _configured := false
var _quality := ""
var _custom_key := ""
var _budget_clock := 0.0

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS

func _process(delta: float) -> void:
    if not OS.has_feature("mobile"):
        return
    var scene := get_tree().current_scene
    var quality := "Balanced"
    var custom: Dictionary = {}
    if scene != null:
        var visuals = scene.get("visuals")
        if visuals != null:
            quality = str(visuals.get("quality"))
            var custom_value = visuals.get("custom")
            if custom_value is Dictionary:
                custom = custom_value
    var custom_key := JSON.stringify(custom)
    if not _configured or quality != _quality or custom_key != _custom_key:
        manager.configure(quality, custom)
        _quality = quality
        _custom_key = custom_key
        _configured = true
    manager.update_frame(delta, get_viewport())
    _budget_clock += delta
    if _budget_clock >= 0.5:
        _budget_clock = 0.0
        _apply_scene_budgets(scene)

func _apply_scene_budgets(scene: Node) -> void:
    if scene == null or not _configured:
        return
    var active := manager.effective_policy()
    active["quality"] = manager.quality
    active["renderer"] = manager.renderer
    var sun_value = scene.get("sun")
    if sun_value is DirectionalLight3D:
        var sun := sun_value as DirectionalLight3D
        sun.directional_shadow_max_distance = float(active.shadow_distance)
    apply_streamer_material_policy(scene, active)
    for node in get_tree().get_nodes_in_group("yardman_render_quality"):
        if node.has_method("apply_render_policy"):
            node.call("apply_render_policy", active)

func apply_streamer_material_policy(scene: Node, active: Dictionary) -> void:
    if scene == null:
        return
    var renderer := str(active.get("renderer", manager.renderer))
    var quality_name := str(active.get("quality", manager.quality))
    var road_safe := str(active.get("road_variant", "high")) == "safe"
    var terrain_safe := str(active.get("terrain_variant", "3layer")) == "2layer"
    var road_shader := MaterialRegistry.shader_for("road", renderer, quality_name, road_safe)
    var terrain_shader := MaterialRegistry.shader_for("terrain", renderer, quality_name, terrain_safe)

    var roads_value = scene.get("roads")
    if roads_value is Object:
        _apply_road_material(roads_value, "_asphalt_material", road_shader, active)
        _apply_road_material(roads_value, "_dirt_material", road_shader, active)

    var terrain_value = scene.get("terrain")
    if terrain_value is Object:
        var loaded_value = terrain_value.get("_loaded")
        if loaded_value is Dictionary:
            for tile_root in loaded_value.values():
                if tile_root is Node:
                    _apply_terrain_shader_to_tree(tile_root, terrain_shader)
        var far_value = terrain_value.get("_far_root")
        if far_value is Node:
            _apply_terrain_shader_to_tree(far_value, terrain_shader)

func _apply_road_material(owner: Object, property_name: String, selected: Shader, active: Dictionary) -> void:
    var value = owner.get(property_name)
    if value is ShaderMaterial:
        var material := value as ShaderMaterial
        material.shader = selected
        material.set_shader_parameter("visibility_distance", float(active.get("road_visibility", 2200.0)))

func _apply_terrain_shader_to_tree(root: Node, selected: Shader) -> void:
    if root is MeshInstance3D:
        _apply_terrain_shader_to_instance(root as MeshInstance3D, selected)
    for node in root.find_children("*", "MeshInstance3D", true, false):
        _apply_terrain_shader_to_instance(node as MeshInstance3D, selected)

func _apply_terrain_shader_to_instance(instance: MeshInstance3D, selected: Shader) -> void:
    var override := instance.material_override
    if _is_terrain_material(override):
        (override as ShaderMaterial).shader = selected
        instance.set_meta("yardman_terrain_variant", selected.resource_path)
    var mesh := instance.mesh
    if mesh == null:
        return
    for surface in range(mesh.get_surface_count()):
        var material := mesh.surface_get_material(surface)
        if _is_terrain_material(material):
            (material as ShaderMaterial).shader = selected
            instance.set_meta("yardman_terrain_variant", selected.resource_path)

func _is_terrain_material(material: Material) -> bool:
    if not material is ShaderMaterial:
        return false
    var shader := (material as ShaderMaterial).shader
    if shader == null:
        return false
    return shader.resource_path in [MaterialRegistry.TERRAIN_HIGH.resource_path, MaterialRegistry.TERRAIN_SAFE.resource_path]

func set_thermal_stage(stage: int) -> void:
    manager.set_thermal_stage(stage)
    if OS.has_feature("mobile"):
        manager.apply_viewport(get_viewport())
        _apply_scene_budgets(get_tree().current_scene)

func set_adaptive_resolution_enabled(enabled: bool) -> void:
    manager.adaptive_resolution_enabled = enabled

func runtime_snapshot() -> Dictionary:
    var result := manager.effective_policy()
    result["renderer"] = manager.renderer
    result["quality"] = manager.quality
    result["resolution_scale"] = manager.current_scale
    result["thermal_stage"] = manager.thermal_stage
    result["configured"] = _configured
    return result
