extends Node

# Map-first presentation and validated renderer-policy bootstrap. This remains
# the single runtime autoload: graphics R&D is integrated here without reviving
# jobs, traffic, pedestrians, economy, or other retired simulation systems.
const ManagerScript = preload("res://scripts/render_quality_manager.gd")
const MaterialRegistry = preload("res://scripts/render_material_registry.gd")

var manager = ManagerScript.new()
var _applied := false
var _scene: Node
var _buildings: JamaicaBuildingStreamer
var _terrain: Node
var _policy_clock := 0.0
var _timing_enabled := false

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    set_process(true)

func _process(delta: float) -> void:
    if not _applied:
        var scene := get_tree().current_scene
        if scene == null or not scene.has_method("set_quality"):
            return
        _apply_initial(scene)

    if _scene == null:
        return

    if OS.has_feature("mobile"):
        if get_tree().paused:
            manager.reset_frame_history()
        else:
            if not _timing_enabled:
                RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
                _timing_enabled = true
            var gpu_ms := RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid())
            manager.update_frame(delta, get_viewport(), false, gpu_ms)

    _policy_clock += delta
    if _policy_clock >= 0.5:
        _policy_clock = 0.0
        _apply_live_policy()

func _apply_initial(scene: Node) -> void:
    _scene = scene

    # Keep the current geographic/streaming stack, but present it at the real
    # quality target instead of an obsolete CI/performance profile.
    scene.call("set_quality", "Quality")
    manager.configure("Quality")
    if OS.has_feature("mobile"):
        manager.apply_viewport(get_viewport())
    else:
        # Desktop/headless validation remains full-resolution Compatibility.
        get_viewport().scaling_3d_scale = 1.0

    var environment_value = scene.get("environment")
    if environment_value is Environment:
        var environment: Environment = environment_value
        environment.tonemap_exposure = 1.03
        environment.ambient_light_energy = clampf(environment.ambient_light_energy, 0.62, 0.72)
        environment.ambient_light_sky_contribution = maxf(environment.ambient_light_sky_contribution, 0.30)
        environment.fog_density = minf(environment.fog_density, 0.000016)

    var sun_value = scene.get("sun")
    if sun_value is DirectionalLight3D:
        var sun: DirectionalLight3D = sun_value
        sun.shadow_enabled = true
        sun.directional_shadow_max_distance = maxf(sun.directional_shadow_max_distance, 220.0)
        sun.shadow_bias = minf(sun.shadow_bias, 0.035)

    var buildings_value = scene.get("buildings")
    if buildings_value is JamaicaBuildingStreamer:
        _buildings = buildings_value
        _buildings.quality = "Quality"
        _buildings.draw_distance = 1400.0
        _buildings.max_loaded_cells = maxi(_buildings.max_loaded_cells, 176)
        if not _buildings.cell_ready.is_connected(_on_building_cell_ready):
            _buildings.cell_ready.connect(_on_building_cell_ready)
        for entry in _buildings._loaded.values():
            _upgrade_building_cell(entry.root)

    var terrain_value = scene.get("terrain")
    if terrain_value is Node:
        _terrain = terrain_value
        if _terrain.has_signal("tile_ready") and not _terrain.tile_ready.is_connected(_on_terrain_tile_ready):
            _terrain.tile_ready.connect(_on_terrain_tile_ready)

    _applied = true
    _apply_live_policy()

func _active_policy() -> Dictionary:
    var active := manager.effective_policy()
    active["quality"] = manager.quality
    active["renderer"] = manager.renderer
    active["thermal_stage"] = manager.thermal_stage
    return active

func _apply_live_policy() -> void:
    if _scene == null:
        return
    var active := _active_policy()
    apply_streamer_material_policy(_scene, active)
    if _terrain != null:
        var coastline_value = _terrain.get("coastline")
        if coastline_value is Node and coastline_value.has_method("apply_render_policy"):
            coastline_value.call("apply_render_policy", active, str(active.renderer))

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
        if roads_value.get("surface_visibility_distance") != null:
            roads_value.set("surface_visibility_distance", float(active.get("road_visibility", 2600.0)))

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
        material.set_shader_parameter("visibility_distance", float(active.get("road_visibility", 2600.0)))

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

func _on_terrain_tile_ready(_tile: Vector2i) -> void:
    _apply_live_policy()

func _on_building_cell_ready(cell: Vector2i, _building_count: int) -> void:
    if _buildings == null:
        return
    var key := "%d:%d" % [cell.x, cell.y]
    if not _buildings._loaded.has(key):
        return
    _upgrade_building_cell(_buildings._loaded[key].root)

func _upgrade_building_cell(root: Node3D) -> void:
    if root == null:
        return
    for child in root.get_children():
        if child is MeshInstance3D:
            child.visibility_range_end = 1650.0
            child.visibility_range_end_margin = 128.0
        elif child is MultiMeshInstance3D and str(child.name).begins_with("ReferenceFacade"):
            child.visibility_range_end = 240.0
            child.visibility_range_end_margin = 30.0
