extends Node

# Android-only runtime bridge for Yardman's renderer policy. Desktop/headless
# validation remains Compatibility and is intentionally not dynamically scaled.
const ManagerScript = preload("res://scripts/render_quality_manager.gd")

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
    var sun_value = scene.get("sun")
    if sun_value is DirectionalLight3D:
        var sun := sun_value as DirectionalLight3D
        sun.directional_shadow_max_distance = float(active.shadow_distance)
    for node in get_tree().get_nodes_in_group("yardman_render_quality"):
        if node.has_method("apply_render_policy"):
            node.call("apply_render_policy", active)

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
