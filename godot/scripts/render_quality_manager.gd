extends RefCounted
class_name YardmanRenderQualityManager

# Runtime policy implementing the Android GPU contract without collapsing the
# intended visual feature set. Feature families remain separate; this manager
# selects budgets and resolution rather than deleting systems.
const POLICIES := {
    "Performance": {
        "target_fps": 60, "resolution_min": 0.60, "resolution_default": 0.75, "resolution_max": 0.85,
        "shadow_distance": 62.0, "road_visibility": 1800.0, "road_variant": "safe", "water_variant": "opaque",
        "terrain_variant": "2layer", "screen_effects": false, "reflection_budget": 1,
    },
    "Balanced": {
        "target_fps": 45, "resolution_min": 0.70, "resolution_default": 0.85, "resolution_max": 0.95,
        "shadow_distance": 88.0, "road_visibility": 2400.0, "road_variant": "high", "water_variant": "dual_normal",
        "terrain_variant": "2layer", "screen_effects": false, "reflection_budget": 2,
    },
    "Quality": {
        "target_fps": 30, "resolution_min": 0.78, "resolution_default": 0.95, "resolution_max": 1.00,
        "shadow_distance": 118.0, "road_visibility": 2800.0, "road_variant": "high", "water_variant": "dual_normal",
        "terrain_variant": "3layer", "screen_effects": true, "reflection_budget": 3,
    },
    "Ultra": {
        "target_fps": 30, "resolution_min": 0.82, "resolution_default": 1.00, "resolution_max": 1.00,
        "shadow_distance": 145.0, "road_visibility": 3200.0, "road_variant": "high", "water_variant": "depth",
        "terrain_variant": "3layer", "screen_effects": true, "reflection_budget": 4,
    },
    "Custom": {
        "target_fps": 45, "resolution_min": 0.55, "resolution_default": 1.00, "resolution_max": 1.00,
        "shadow_distance": 100.0, "road_visibility": 2600.0, "road_variant": "high", "water_variant": "dual_normal",
        "terrain_variant": "2layer", "screen_effects": false, "reflection_budget": 2,
    },
}

const GLES_CAP := {
    "target_fps": 30,
    "resolution_max": 0.82,
    "shadow_distance": 78.0,
    "road_visibility": 2200.0,
    "road_variant": "safe",
    "water_variant": "opaque",
    "terrain_variant": "2layer",
    "screen_effects": false,
    "reflection_budget": 1,
}

# Thermal stages cap requested frame rate only after the device is under
# sustained pressure. Quality/Ultra already target 30 FPS and are unaffected.
const THERMAL_FPS_CAPS := [240, 60, 50, 40, 35, 30]

var quality := "Balanced"
var renderer := "gl_compatibility"
var policy: Dictionary = {}
var current_scale := 0.85
var thermal_stage := 0
var adaptive_resolution_enabled := true
var auto_thermal_enabled := true
var _frame_ms_ema := 16.67
var _slow_seconds := 0.0
var _fast_seconds := 0.0
var _change_cooldown := 0.0
var _thermal_pressure_seconds := 0.0
var _thermal_recovery_seconds := 0.0

static func renderer_family() -> String:
    var key := "rendering/renderer/rendering_method.mobile" if OS.has_feature("mobile") else "rendering/renderer/rendering_method"
    var method := str(ProjectSettings.get_setting(key, "gl_compatibility"))
    if method == "mobile":
        return "vulkan_mobile"
    if method == "gl_compatibility":
        return "gles"
    return method

static func policy_for(requested_quality: String, renderer_family_name: String, custom: Dictionary = {}) -> Dictionary:
    var name := requested_quality if POLICIES.has(requested_quality) else "Balanced"
    var result: Dictionary = POLICIES[name].duplicate(true)
    if name == "Custom":
        for key in ["target_fps", "resolution_min", "resolution_default", "resolution_max", "shadow_distance", "road_visibility"]:
            if custom.has(key):
                result[key] = custom[key]
    if renderer_family_name in ["gles", "gl_compatibility"]:
        result.target_fps = mini(int(result.target_fps), int(GLES_CAP.target_fps))
        result.resolution_max = minf(float(result.resolution_max), float(GLES_CAP.resolution_max))
        result.resolution_default = minf(float(result.resolution_default), float(result.resolution_max))
        result.shadow_distance = minf(float(result.shadow_distance), float(GLES_CAP.shadow_distance))
        result.road_visibility = minf(float(result.road_visibility), float(GLES_CAP.road_visibility))
        result.road_variant = GLES_CAP.road_variant
        result.water_variant = GLES_CAP.water_variant
        result.terrain_variant = GLES_CAP.terrain_variant
        result.screen_effects = GLES_CAP.screen_effects
        result.reflection_budget = GLES_CAP.reflection_budget
    result.resolution_min = minf(float(result.resolution_min), float(result.resolution_max))
    return result

func configure(requested_quality: String, custom: Dictionary = {}, renderer_override: String = "") -> Dictionary:
    quality = requested_quality if POLICIES.has(requested_quality) else "Balanced"
    renderer = renderer_override if not renderer_override.is_empty() else renderer_family()
    policy = policy_for(quality, renderer, custom)
    thermal_stage = 0
    _slow_seconds = 0.0
    _fast_seconds = 0.0
    _change_cooldown = 0.0
    _thermal_pressure_seconds = 0.0
    _thermal_recovery_seconds = 0.0
    current_scale = clampf(float(custom.get("resolution", policy.resolution_default)), float(policy.resolution_min), float(policy.resolution_max))
    _apply_frame_cap()
    return effective_policy()

func effective_policy() -> Dictionary:
    var result := policy.duplicate(true)
    if result.is_empty():
        result = policy_for(quality, renderer if not renderer.is_empty() else renderer_family())
    var stage := clampi(thermal_stage, 0, 5)
    var thermal_scale_loss: float = float([0.0, 0.06, 0.12, 0.18, 0.24, 0.30][stage])
    result.resolution_max = maxf(float(result.resolution_min), float(result.resolution_max) - thermal_scale_loss)
    result.shadow_distance = float(result.shadow_distance) * float([1.0, 0.90, 0.80, 0.70, 0.62, 0.55][stage])
    result.vegetation_factor = float([1.0, 1.0, 0.88, 0.74, 0.62, 0.52][stage])
    result.target_fps = mini(int(result.target_fps), int(THERMAL_FPS_CAPS[stage]))
    result.screen_effects = bool(result.screen_effects) and stage < 3
    if stage >= 3:
        result.road_variant = "safe"
    if stage >= 4:
        result.water_variant = "opaque"
        result.terrain_variant = "2layer"
        result.reflection_budget = mini(int(result.reflection_budget), 1)
    return result

func set_thermal_stage(stage: int) -> void:
    thermal_stage = clampi(stage, 0, 5)
    var active := effective_policy()
    current_scale = minf(current_scale, float(active.resolution_max))
    _apply_frame_cap()

func _apply_frame_cap() -> void:
    var active := effective_policy()
    Engine.max_fps = maxi(0, int(active.target_fps))

func apply_viewport(viewport: Viewport) -> void:
    if viewport == null:
        return
    var active := effective_policy()
    current_scale = clampf(current_scale, float(active.resolution_min), float(active.resolution_max))
    viewport.scaling_3d_scale = current_scale

func update_frame(delta: float, viewport: Viewport = null, force_adaptive: bool = false) -> float:
    if delta <= 0.0:
        return current_scale
    _frame_ms_ema = lerpf(_frame_ms_ema, delta * 1000.0, clampf(delta * 3.0, 0.02, 0.22))
    _change_cooldown = maxf(0.0, _change_cooldown - delta)
    if not adaptive_resolution_enabled or (not force_adaptive and not OS.has_feature("mobile")):
        apply_viewport(viewport)
        return current_scale
    var active := effective_policy()
    var target_ms := 1000.0 / maxf(float(active.target_fps), 1.0)
    if _frame_ms_ema > target_ms * 1.10:
        _slow_seconds += delta
        _fast_seconds = 0.0
    elif _frame_ms_ema < target_ms * 0.78:
        _fast_seconds += delta
        _slow_seconds = 0.0
    else:
        _slow_seconds = maxf(0.0, _slow_seconds - delta * 0.5)
        _fast_seconds = maxf(0.0, _fast_seconds - delta * 0.5)
    if _change_cooldown <= 0.0 and _slow_seconds >= 1.25:
        current_scale = maxf(float(active.resolution_min), current_scale - 0.05)
        _slow_seconds = 0.0
        _change_cooldown = 1.5
    elif _change_cooldown <= 0.0 and _fast_seconds >= 5.0:
        current_scale = minf(float(active.resolution_max), current_scale + 0.025)
        _fast_seconds = 0.0
        _change_cooldown = 2.0
    _update_thermal_pressure(delta, effective_policy(), force_adaptive)
    apply_viewport(viewport)
    return current_scale

func _update_thermal_pressure(delta: float, active: Dictionary, force_adaptive: bool) -> void:
    if not auto_thermal_enabled or (not force_adaptive and not OS.has_feature("mobile")):
        _thermal_pressure_seconds = 0.0
        _thermal_recovery_seconds = 0.0
        return
    var target_ms := 1000.0 / maxf(float(active.target_fps), 1.0)
    var at_floor := current_scale <= float(active.resolution_min) + 0.001
    if at_floor and _frame_ms_ema > target_ms * 1.15:
        _thermal_pressure_seconds += delta
        _thermal_recovery_seconds = 0.0
    elif thermal_stage > 0 and _frame_ms_ema < target_ms * 0.74:
        _thermal_recovery_seconds += delta
        _thermal_pressure_seconds = maxf(0.0, _thermal_pressure_seconds - delta)
    else:
        _thermal_pressure_seconds = maxf(0.0, _thermal_pressure_seconds - delta * 0.5)
        _thermal_recovery_seconds = maxf(0.0, _thermal_recovery_seconds - delta * 0.5)

    if _thermal_pressure_seconds >= 8.0 and thermal_stage < 5:
        _thermal_pressure_seconds = 0.0
        _thermal_recovery_seconds = 0.0
        set_thermal_stage(thermal_stage + 1)
    elif _thermal_recovery_seconds >= 30.0 and thermal_stage > 0:
        _thermal_pressure_seconds = 0.0
        _thermal_recovery_seconds = 0.0
        set_thermal_stage(thermal_stage - 1)
