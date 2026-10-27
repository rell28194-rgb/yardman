extends "res://scripts/weather_fx_runtime.gd"

# Godot 4.7 has no bool(...) constructor. Keep the recovered weather runtime
# unchanged and override only the frame update that used those invalid casts.
func _process(delta: float) -> void:
    var safe_delta := clampf(delta, 0.0, 0.25) if is_finite(delta) else 0.016
    var game := get_tree().current_scene if get_tree() != null else null
    var target := 0.0
    var quality := "Balanced"
    var reduced_motion := false
    var camera: Camera3D = null
    if game != null:
        var visuals = game.get("visuals")
        if visuals != null:
            quality = str(visuals.get("quality"))
        var touch = game.get("touch")
        if touch != null:
            var settings = touch.get("settings")
            if settings is Dictionary:
                reduced_motion = settings.get("reduced_motion", false) == true
        camera = game.get("camera") as Camera3D
        if game.get("world_ready") == true:
            target = target_intensity(float(game.get("day_hour")), str(game.get("current_parish")))
    _intensity = move_toward(_intensity, target, safe_delta * (0.55 if target > _intensity else 0.38))
    _intensity = clampf(_intensity, 0.0, 1.0)
    if _intensity >= 0.18:
        _after_rain = maxf(_after_rain, _intensity)
    else:
        _after_rain = move_toward(_after_rain, 0.0, safe_delta * 0.045)
    _update_rain(camera, quality, reduced_motion)
    _update_mist(camera, quality, reduced_motion)
    _update_environment(game)
    _material_clock += safe_delta
    if _material_clock >= UPDATE_MATERIAL_INTERVAL:
        _material_clock = 0.0
        _apply_wetness()
