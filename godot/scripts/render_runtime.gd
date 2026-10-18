extends Node

# Android-only runtime bridge for Yardman's renderer policy. Desktop/headless
# validation remains Compatibility and is intentionally not dynamically scaled.
const ManagerScript = preload("res://scripts/render_quality_manager.gd")
const MaterialRegistry = preload("res://scripts/render_material_registry.gd")
const StreamingBudgetScript = preload("res://scripts/streaming_budget_runtime.gd")

# Geometry streamers used to own independent time slices, which meant roads,
# terrain, buildings and roadside vegetation could all spend their maximum in
# one frame. These envelopes cap aggregate integration work instead. Ultra keeps
# the widest residency/detail window; it does not get permission to hitch.
const STREAM_INTEGRATION_BASE_US := {
    "Performance": 3400,
    "Balanced": 4600,
    "Quality": 5800,
    "Ultra": 6800,
    "Custom": 4600,
}
const STREAM_THERMAL_FACTORS := [1.0, 0.95, 0.86, 0.74, 0.62, 0.52]

var manager = ManagerScript.new()
var _configured := false
var _quality := ""
var _custom_key := ""
var _budget_clock := 0.0
var _refresh_clock := 0.0
var _timing_enabled := false

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    if get_node_or_null("StreamingBudgetRuntime") == null:
        var streaming_budget := StreamingBudgetScript.new()
        streaming_budget.name = "StreamingBudgetRuntime"
        add_child(streaming_budget)

func _process(delta: float) -> void:
    if not OS.has_feature("mobile"):
        return
    if get_tree().paused:
        manager.reset_frame_history()
        return
    if not _timing_enabled:
        RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
        _timing_enabled = true
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
    _refresh_clock += delta
    if _refresh_clock >= 2.0:
        _refresh_clock = 0.0
        var screen_hz := ManagerScript.display_refresh_rate()
        if absf(screen_hz - manager.refresh_rate) > 0.1:
            manager.set_refresh_rate(screen_hz)
    var gpu_ms := RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid())
    manager.update_frame(delta, get_viewport(), false, gpu_ms)
    _budget_clock += delta
    if _budget_clock >= 0.5:
        _budget_clock = 0.0
        _apply_scene_budgets(scene)

static func stream_integration_budget_for(quality: String, thermal_stage: int) -> Dictionary:
    var name := quality if STREAM_INTEGRATION_BASE_US.has(quality) else "Balanced"
    var stage := clampi(thermal_stage, 0, STREAM_THERMAL_FACTORS.size() - 1)
    var factor := float(STREAM_THERMAL_FACTORS[stage])
    var total_us := maxi(2600, int(round(float(STREAM_INTEGRATION_BASE_US[name]) * factor)))
    # Match the roadside scheduler's own thermal ladder and reserve its slice
    # before assigning the remaining budget to the other three streamers.
    var roadside_us := maxi(700, int(round(1400.0 * factor)))
    var shared_us := maxi(1800, total_us - roadside_us)
    var road_us := maxi(650, int(floor(float(shared_us) * 0.36)))
    var terrain_us := maxi(650, int(floor(float(shared_us) * 0.36)))
    var building_us := maxi(500, shared_us - road_us - terrain_us)
    var assigned_us := road_us + terrain_us + building_us + roadside_us
    return {
        "quality": name,
        "thermal_stage": stage,
        "total_us": total_us,
        "road_us": road_us,
        "terrain_us": terrain_us,
        "building_us": building_us,
        "roadside_us": roadside_us,
        "assigned_us": assigned_us,
    }

func _apply_scene_budgets(scene: Node) -> void:
    if scene == null or not _configured:
        return
    var active := manager.effective_policy()
    active["quality"] = manager.quality
    active["renderer"] = manager.renderer
    active["thermal_stage"] = manager.thermal_stage
    var sun_value = scene.get("sun")
    if sun_value is DirectionalLight3D:
        var sun := sun_value as DirectionalLight3D
        sun.directional_shadow_max_distance = float(active.shadow_distance)
    apply_streamer_material_policy(scene, active)
    for node in get_tree().get_nodes_in_group("yardman_render_quality"):
        if node.has_method("apply_render_policy"):
            node.call("apply_render_policy", active)
    _apply_shared_streaming_budget(scene, active)

func _apply_shared_streaming_budget(scene: Node, active: Dictionary) -> void:
    var allocation := stream_integration_budget_for(
        str(active.get("quality", manager.quality)),
        int(active.get("thermal_stage", manager.thermal_stage)))
    var roads = scene.get("roads")
    var terrain = scene.get("terrain")
    var buildings = scene.get("buildings")
    if roads is Object:
        roads.set("geometry_budget_us", int(allocation.road_us))
    if terrain is Object:
        terrain.set("geometry_budget_us", int(allocation.terrain_us))
    if buildings is Object:
        buildings.set("geometry_budget_us", int(allocation.building_us))
    # Keep the full aggregate allocation visible to diagnostics without making
    # the streamers depend on this autoload's implementation details.
    scene.set_meta("yardman_stream_integration_budget", allocation)

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
    result["stream_integration"] = stream_integration_budget_for(manager.quality, manager.thermal_stage)
    result.merge(manager.timing_snapshot())
    return result