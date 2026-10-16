extends SceneTree

const Weather = preload("res://scripts/atmosphere_fx.gd")
const Registry = preload("res://scripts/render_material_registry.gd")

var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("WEATHER_TEST: " + message)

func _check_wet_shader(renderer: String) -> void:
    var shader: Shader = Registry.shader_for("road", renderer, "Quality")
    var source := FileAccess.get_file_as_string(shader.resource_path)
    _check(source.contains("uniform float wetness"), "%s road shader has no wetness uniform" % renderer)
    _check(source.contains("uniform float standing_water"), "%s road shader has no standing-water uniform" % renderer)
    var material := ShaderMaterial.new()
    material.shader = shader
    material.set_shader_parameter("wetness", 0.75)
    material.set_shader_parameter("standing_water", 0.42)
    _check(is_equal_approx(float(material.get_shader_parameter("wetness")), 0.75), "%s wetness uniform did not bind" % renderer)
    _check(is_equal_approx(float(material.get_shader_parameter("standing_water")), 0.42), "%s standing-water uniform did not bind" % renderer)

func _run() -> void:
    _check(is_equal_approx(Weather._standing_water_target(1.0, 1.0), 1.0), "Saturated storm does not permit full standing water")
    _check(is_zero_approx(Weather._standing_water_target(0.0, 1.0)), "Standing water target formed without active rain")
    _check(is_zero_approx(Weather._standing_water_target(1.0, 0.0)), "Standing water target formed on a dry surface")

    var weather = Weather.new()
    _check(weather.set_weather("storm"), "storm weather mode was rejected")
    weather._update_weather_state(6.0)
    var storm: Dictionary = weather.weather_snapshot()
    _check(str(storm.mode) == "storm", "weather mode did not persist")
    _check(float(storm.target_rain) == 1.0, "storm target is not full rain")
    _check(float(storm.rain_intensity) > 0.9, "rain did not ramp toward target")
    _check(float(storm.wetness) > 0.9, "surface wetness did not accumulate")
    _check(float(storm.standing_water) > 0.5, "sustained storm did not accumulate standing road water")

    weather.set_weather("clear")
    var before_dry := float(weather.weather_snapshot().wetness)
    var before_pool := float(weather.weather_snapshot().standing_water)
    weather._update_weather_state(4.0)
    var clearing: Dictionary = weather.weather_snapshot()
    _check(float(clearing.rain_intensity) < float(storm.rain_intensity), "rain did not decay after clearing")
    _check(float(clearing.wetness) <= before_dry, "wet roads became wetter after rain cleared")
    _check(float(clearing.standing_water) < before_pool, "standing water did not begin draining after rain cleared")
    _check(float(clearing.standing_water) > 0.0, "standing water vanished instantly instead of draining")
    _check(not weather.set_weather("hurricane-force-unimplemented"), "unknown weather mode was accepted")

    _check_wet_shader("vulkan_mobile")
    _check_wet_shader("gles")

    weather.apply_render_policy({"quality": "Ultra", "renderer": "vulkan_mobile", "road_variant": "high"})
    _check(int(weather.weather_snapshot().particle_budget) >= 1300, "Vulkan Ultra rain budget was not elevated")
    weather.apply_render_policy({"quality": "Ultra", "renderer": "gles", "road_variant": "safe"})
    _check(int(weather.weather_snapshot().particle_budget) <= 620, "GLES rain budget exceeded safe cap")

    weather.free()
    await process_frame
    print("YARDMAN_WEATHER_TEST %s transitions=1 wet_roads=2 standing_water=1 renderer_budget=1 cleanup=1" % ("PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)
