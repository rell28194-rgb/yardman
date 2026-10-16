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

# Reduce frame rate last, after resolution, shadows and material budgets.
const THERMAL_FPS_CAPS := [60, 60, 60, 60, 60, 30]
const FRAME_CADENCES := [60, 45, 40, 30, 25, 24, 20, 15]

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
var refresh_rate := 60.0
var _gpu_ms_ema := 0.0
var gpu_timing_available := false

static func renderer_family() -> String:
    # Project settings describe intent; command-line selection and a failed
    # Vulkan startup can select a different backend. Materials follow reality.
    var actual := RenderingServer.get_current_rendering_method()
    if not actual.is_empty():
        return normalize_renderer(actual)
    var key := "rendering/renderer/rendering_method.mobile" if OS.has_feature("mobile") else "rendering/renderer/rendering_method"
    return normalize_renderer(str(ProjectSettings.get_setting(key, "gl_compatibility")))

static func normalize_renderer(method: String) -> String:
    if method in ["mobile", "vulkan_mobile"]:
        return "vulkan_mobile"
    if method in ["gl_compatibility", "gles", "opengl3"]:
        return "gles"
    return method

static func _finite_number(value: Variant, fallback: float) -> float:
    if not (value is int or value is float):
        return fallback
    var number := float(value)
    return number if is_finite(number) else fallback

static func display_refresh_rate() -> float:
    if DisplayServer.get_name() == "headless":
        return 60.0
    return sanitize_refresh_rate(DisplayServer.screen_get_refresh_rate())

static func sanitize_refresh_rate(value: float) -> float:
    return value if is_finite(value) and value >= 20.0 and value <= 1000.0 else 60.0

static func paced_fps(requested: int, screen_hz: float) -> int:
    var hz := sanitize_refresh_rate(screen_hz)
    for cadence in FRAME_CADENCES:
        if cadence > requested:
            continue
        var cycles: float = hz / float(cadence)
        if cycles >= 0.98 and absf(cycles - roundf(cycles)) <= 0.02:
            return int(cadence)
    # Unusual refresh rates still get an integer number of display intervals.
    return maxi(1, int(roundf(hz / ceilf(hz / maxf(float(requested), 1.0)))))

static func policy_for(requested_quality: String, renderer_family_name: String, custom: Dictionary = {}) -> Dictionary:
    var name := requested_quality if POLICIES.has(requested_quality) else "Balanced"
    var result: Dictionary = POLICIES[name].duplicate(true)
    if name == "Custom":
        for key in ["target_fps", "resolution_min", "resolution_default", "resolution_max", "shadow_distance", "road_visibility"]:
            if custom.has(key):
                result[key] = _finite_number(custom[key], float(result[key]))
    result.target_fps = clampi(int(result.target_fps), 30, 60)
    result.resolution_min = clampf(float(result.resolution_min), 0.50, 1.0)
    result.resolution_max = clampf(float(result.resolution_max), float(result.resolution_min), 1.0)
    result.resolution_default = clampf(float(result.resolution_default), float(result.resolution_min), float(result.resolution_max))
    result.shadow_distance = clampf(float(result.shadow_distance), 10.0, 200.0)
    result.road_visibility = clampf(float(result.road_visibility), 500.0, 4000.0)
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

func configure(requested_quality: String, custom: Dictionary = {}, renderer_override: String = "", refresh_override: float = -1.0) -> Dictionary:
    quality = requested_quality if POLICIES.has(requested_quality) else "Balanced"
    renderer = normalize_renderer(renderer_override) if not renderer_override.is_empty() else renderer_family()
    policy = policy_for(quality, renderer, custom)
    refresh_rate = sanitize_refresh_rate(refresh_override) if refresh_override != -1.0 else display_refresh_rate()
    # A quality-menu change must not clear sustained device pressure.
    reset_frame_history()
    var active := effective_policy()
    current_scale = clampf(_finite_number(custom.get("resolution", policy.resolution_default), float(policy.resolution_default)), float(active.resolution_min), float(active.resolution_max))
    _apply_frame_cap()
    return effective_policy()

func reset_frame_history() -> void:
    _frame_ms_ema = 1000.0 / maxf(float(effective_policy().target_fps), 1.0)
    _gpu_ms_ema = 0.0
    gpu_timing_available = false
    _slow_seconds = 0.0
    _fast_seconds = 0.0
    _change_cooldown = 0.0
    _thermal_pressure_seconds = 0.0
    _thermal_recovery_seconds = 0.0
func set_refresh_rate(screen_hz: float) -> void:
    refresh_rate = sanitize_refresh_rate(screen_hz)
    reset_frame_history()
    _apply_frame_cap()

func effective_policy() -> Dictionary:
    var result := policy.duplicate(true)
    if result.is_empty():
        result = policy_for(quality, renderer if not renderer.is_empty() else renderer_family())
    var stage := clampi(thermal_stage, 0, 5)
    var thermal_scale_loss: float = float([0.0, 0.06, 0.12, 0.18, 0.24, 0.30][stage])
    result.resolution_max = maxf(float(result.resolution_min), float(result.resolution_max) - thermal_scale_loss)
    result.shadow_distance = float(result.shadow_distance) * float([1.0, 0.90, 0.80, 0.70, 0.62, 0.55][stage])
    result.vegetation_factor = float([1.0, 1.0, 0.88, 0.74, 0.62, 0.52][stage])
    result.requested_fps = mini(int(result.target_fps), int(THERMAL_FPS_CAPS[stage]))
    result.target_fps = paced_fps(int(result.requested_fps), refresh_rate)
    result.refresh_rate = refresh_rate
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

func update_frame(delta: float, viewport: Viewport = null, force_adaptive: bool = false, gpu_ms: float = -1.0) -> float:
    if not is_finite(delta) or delta <= 0.0:
        return current_scale
    if delta > 0.5:
        # App resumes, loading and debugger pauses are not sustained pressure.
        reset_frame_history()
        return current_scale
    _frame_ms_ema = lerpf(_frame_ms_ema, delta * 1000.0, clampf(delta * 3.0, 0.02, 0.22))
    gpu_timing_available = is_finite(gpu_ms) and gpu_ms > 0.0
    if gpu_timing_available:
        _gpu_ms_ema = gpu_ms if _gpu_ms_ema <= 0.0 else lerpf(_gpu_ms_ema, gpu_ms, clampf(delta * 3.0, 0.02, 0.22))
    else:
        _gpu_ms_ema = 0.0
    _change_cooldown = maxf(0.0, _change_cooldown - delta)
    if not adaptive_resolution_enabled or (not force_adaptive and not OS.has_feature("mobile")):
        apply_viewport(viewport)
        return current_scale
    var active := effective_policy()
    var target_ms := 1000.0 / maxf(float(active.target_fps), 1.0)
    if _frame_ms_ema > target_ms * 1.10:
        _slow_seconds += delta
        _fast_seconds = 0.0
    elif _has_headroom(target_ms):
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

func _has_headroom(target_ms: float) -> bool:
    if gpu_timing_available:
        # Capped/VSync frame time includes waiting, so it cannot show spare GPU
        # capacity. Require measured GPU headroom AND stable frame delivery.
        return _gpu_ms_ema < target_ms * 0.70 and _frame_ms_ema <= target_ms * 1.05
    return _frame_ms_ema < target_ms * 0.74

func timing_snapshot() -> Dictionary:
    return {"frame_ms": _frame_ms_ema, "gpu_ms": _gpu_ms_ema, "gpu_timing_available": gpu_timing_available}

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
    elif thermal_stage > 0 and _has_headroom(target_ms):
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
