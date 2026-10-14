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
    var material := ShaderMaterial.new()
    material.shader = shader
    material.set_shader_parameter("wetness", 0.75)
    _check(is_equal_approx(float(material.get_shader_parameter("wetness")), 0.75), "%s wetness uniform did not bind" % renderer)

func _run() -> void:
    var weather = Weather.new()
    _check(weather.set_weather("storm"), "storm weather mode was rejected")
    weather._update_weather_state(2.0)
    var storm: Dictionary = weather.weather_snapshot()
    _check(str(storm.mode) == "storm", "weather mode did not persist")
    _check(float(storm.target_rain) == 1.0, "storm target is not full rain")
    _check(float(storm.rain_intensity) > 0.0, "rain did not ramp toward target")
    _check(float(storm.wetness) > 0.0, "surface wetness did not accumulate")

    weather.set_weather("clear")
    var before_dry := float(weather.weather_snapshot().wetness)
    weather._update_weather_state(4.0)
    var clearing: Dictionary = weather.weather_snapshot()
    _check(float(clearing.rain_intensity) < float(storm.rain_intensity), "rain did not decay after clearing")
    _check(float(clearing.wetness) <= before_dry, "wet roads became wetter after rain cleared")
    _check(not weather.set_weather("hurricane-force-unimplemented"), "unknown weather mode was accepted")

    _check_wet_shader("vulkan_mobile")
    _check_wet_shader("gles")

    weather.apply_render_policy({"quality": "Ultra", "renderer": "vulkan_mobile", "road_variant": "high"})
    _check(int(weather.weather_snapshot().particle_budget) >= 1300, "Vulkan Ultra rain budget was not elevated")
    weather.apply_render_policy({"quality": "Ultra", "renderer": "gles", "road_variant": "safe"})
    _check(int(weather.weather_snapshot().particle_budget) <= 620, "GLES rain budget exceeded safe cap")

    weather.free()
    await process_frame
    print("YARDMAN_WEATHER_TEST %s transitions=1 wet_roads=2 renderer_budget=1 cleanup=1" % ("PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)
