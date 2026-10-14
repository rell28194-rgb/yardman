extends Node
class_name YardmanVehicleHeadlightRuntime

var renderer := "mobile"
var quality := "Balanced"
var thermal_stage := 0
var _refresh_clock := 0.0
var _active_lights := 0
var _last_factor := 0.0

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    add_to_group("yardman_render_quality")

func _process(delta: float) -> void:
    _refresh_clock += delta
    if _refresh_clock < 0.10:
        return
    _refresh_clock = 0.0
    var scene := get_tree().current_scene
    if scene == null:
        _active_lights = 0
        return
    var controller = scene.get("vehicle")
    if controller == null:
        _active_lights = 0
        return
    var lights_value = controller.get("_headlights")
    if not lights_value is Array:
        _active_lights = 0
        return
    var hour := float(scene.get("day_hour"))
    var rain := 0.0
    var atmosphere := get_node_or_null("/root/AtmosphereFX")
    if atmosphere != null:
        rain = clampf(float(atmosphere.get("rain_intensity")), 0.0, 1.0)
    var factor := activation_for(hour, rain)
    var occupied := bool(controller.get("occupied"))
    var budget := budget_for(quality, thermal_stage, renderer)
    _active_lights = apply_lights(lights_value as Array, occupied, factor, budget)
    _last_factor = factor

func apply_render_policy(active: Dictionary) -> void:
    renderer = str(active.get("renderer", renderer))
    quality = str(active.get("quality", quality))
    thermal_stage = clampi(int(active.get("thermal_stage", thermal_stage)), 0, 5)

static func night_factor(hour: float) -> float:
    var h := fmod(hour + 24.0, 24.0)
    if h >= 19.0 or h < 5.25:
        return 1.0
    if h >= 5.25 and h < 6.5:
        return 1.0 - smoothstep(5.25, 6.5, h)
    if h >= 18.0 and h < 19.0:
        return smoothstep(18.0, 19.0, h)
    return 0.0

static func activation_for(hour: float, rain_intensity: float) -> float:
    var night := night_factor(hour)
    var rain := clampf(rain_intensity, 0.0, 1.0)
    var storm_assist := smoothstep(0.34, 0.86, rain) * 0.72
    return clampf(maxf(night, storm_assist), 0.0, 1.0)

static func budget_for(quality_name: String, stage_value: int, renderer_name: String = "mobile") -> Dictionary:
    var energy := 4.2
    var range_m := 46.0
    var angle_deg := 31.0
    match quality_name:
        "Performance":
            energy = 3.2
            range_m = 36.0
            angle_deg = 29.0
        "Quality":
            energy = 4.8
            range_m = 52.0
        "Ultra":
            energy = 5.2
            range_m = 58.0
    if renderer_name == "gl_compatibility" or renderer_name == "gles":
        energy = minf(energy, 3.7)
        range_m = minf(range_m, 40.0)
        angle_deg = minf(angle_deg, 30.0)
    var stage := clampi(stage_value, 0, 5)
    var factor: float = float([1.0, 1.0, 0.94, 0.84, 0.72, 0.62][stage])
    return {
        "energy": maxf(2.25, energy * factor),
        "range_m": maxf(30.0, range_m * lerpf(0.78, 1.0, factor)),
        "angle_deg": angle_deg,
        "thermal_stage": stage,
    }

static func apply_lights(lights: Array, occupied: bool, factor: float, budget: Dictionary) -> int:
    var active := 0
    var level := clampf(factor, 0.0, 1.0)
    for value in lights:
        if not value is SpotLight3D:
            continue
        var light := value as SpotLight3D
        var enabled := occupied and level > 0.015
        light.visible = enabled
        light.light_energy = float(budget.get("energy", 4.2)) * level if enabled else 0.0
        light.spot_range = float(budget.get("range_m", 46.0))
        light.spot_angle = float(budget.get("angle_deg", 31.0))
        light.shadow_enabled = false
        light.distance_fade_enabled = true
        light.distance_fade_begin = maxf(18.0, light.spot_range * 0.62)
        light.distance_fade_length = maxf(10.0, light.spot_range * 0.46)
        if enabled:
            active += 1
    return active

func runtime_snapshot() -> Dictionary:
    return {
        "active_lights": _active_lights,
        "activation": _last_factor,
        "renderer": renderer,
        "quality": quality,
        "thermal_stage": thermal_stage,
    }
