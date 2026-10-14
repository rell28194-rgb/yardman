extends Node
class_name YardmanBuildingNightRuntime

const BuildingShader = preload("res://shaders/building_surface.gdshader")
const NightPolicy = preload("res://scripts/vehicle_headlight_runtime.gd")

var renderer := "mobile"
var quality := "Balanced"
var thermal_stage := 0
var _refresh_clock := 0.0
var _last_night_factor := 0.0
var _last_lit_fraction := 0.0
var _last_applied := false

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    add_to_group("yardman_render_quality")

func _process(delta: float) -> void:
    _refresh_clock += delta
    if _refresh_clock < 0.25:
        return
    _refresh_clock = 0.0
    var scene := get_tree().current_scene
    if scene == null:
        _last_applied = false
        return
    var buildings = scene.get("buildings")
    if buildings == null:
        _last_applied = false
        return
    var material = buildings.get("_wall_material")
    var hour := float(scene.get("day_hour"))
    var budget := budget_for(quality, thermal_stage, renderer)
    _last_applied = apply_material(material, hour, budget)
    _last_night_factor = NightPolicy.night_factor(hour)
    _last_lit_fraction = effective_lit_fraction(hour, budget)

func apply_render_policy(active: Dictionary) -> void:
    renderer = str(active.get("renderer", renderer))
    quality = str(active.get("quality", quality))
    thermal_stage = clampi(int(active.get("thermal_stage", thermal_stage)), 0, 5)

static func lit_fraction_for_hour(hour: float) -> float:
    var h := fmod(hour + 24.0, 24.0)
    if h >= 18.0 and h < 22.0:
        return 0.56
    if h >= 22.0 or h < 1.0:
        return 0.40
    if h < 5.0:
        return 0.22
    if h < 6.5:
        return 0.12
    return 0.0

static func budget_for(quality_name: String, stage_value: int, renderer_name: String = "mobile") -> Dictionary:
    var emission := 1.35
    var lit_scale := 1.0
    match quality_name:
        "Performance":
            emission = 1.05
            lit_scale = 0.78
        "Quality":
            emission = 1.55
            lit_scale = 1.08
        "Ultra":
            emission = 1.75
            lit_scale = 1.14
    if renderer_name == "gl_compatibility" or renderer_name == "gles":
        emission = minf(emission, 1.25)
        lit_scale = minf(lit_scale, 0.92)
    var stage := clampi(stage_value, 0, 5)
    var factors: Array[float] = [1.0, 1.0, 0.94, 0.84, 0.74, 0.66]
    var factor: float = factors[stage]
    return {
        "emission": maxf(0.78, emission * factor),
        "lit_scale": maxf(0.58, lit_scale * lerpf(0.80, 1.0, factor)),
        "thermal_stage": stage,
    }

static func effective_lit_fraction(hour: float, budget: Dictionary) -> float:
    if NightPolicy.night_factor(hour) <= 0.001:
        return 0.0
    return clampf(lit_fraction_for_hour(hour) * float(budget.get("lit_scale", 1.0)), 0.0, 0.72)

static func apply_material(material_value, hour: float, budget: Dictionary) -> bool:
    if not material_value is ShaderMaterial:
        return false
    var material := material_value as ShaderMaterial
    if material.shader != BuildingShader:
        return false
    var night := NightPolicy.night_factor(hour)
    var fraction := effective_lit_fraction(hour, budget)
    material.set_shader_parameter("night_factor", night)
    material.set_shader_parameter("window_emission_strength", float(budget.get("emission", 1.35)))
    material.set_shader_parameter("window_lit_threshold", 1.0 - fraction if night > 0.001 else 1.0)
    return true

func runtime_snapshot() -> Dictionary:
    return {
        "applied": _last_applied,
        "night_factor": _last_night_factor,
        "lit_fraction": _last_lit_fraction,
        "renderer": renderer,
        "quality": quality,
        "thermal_stage": thermal_stage,
    }
