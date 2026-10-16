extends SceneTree

const BuildingNight = preload("res://scripts/building_night_runtime.gd")
const BuildingShader = preload("res://shaders/building_surface.gdshader")
var failures := 0

func _init() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("BUILDING_NIGHT_TEST: " + message)

func _run() -> void:
    _check(BuildingNight.lit_fraction_for_hour(19.5) > BuildingNight.lit_fraction_for_hour(3.0), "evening occupancy should exceed pre-dawn activity")
    _check(is_equal_approx(BuildingNight.lit_fraction_for_hour(12.0), 0.0), "midday windows should not be lit")

    var balanced := BuildingNight.budget_for("Balanced", 0, "mobile")
    var hot := BuildingNight.budget_for("Balanced", 5, "mobile")
    var gles := BuildingNight.budget_for("Ultra", 0, "gl_compatibility")
    _check(float(hot.emission) < float(balanced.emission), "thermal policy did not reduce building emission")
    _check(float(gles.emission) <= 1.25, "GLES building emission exceeded fallback cap")
    _check(float(hot.emission) >= 0.78, "thermal policy removed night building visibility")

    var material := ShaderMaterial.new()
    material.shader = BuildingShader
    _check(BuildingNight.apply_material(material, 20.0, balanced), "building shader was not accepted")
    _check(float(material.get_shader_parameter("night_factor")) > 0.9, "night factor was not applied")
    _check(float(material.get_shader_parameter("window_lit_threshold")) < 0.7, "evening lit-window fraction was not applied")
    _check(BuildingNight.apply_material(material, 12.0, balanced), "daytime building update failed")
    _check(is_equal_approx(float(material.get_shader_parameter("night_factor")), 0.0), "daytime building emission stayed active")
    _check(is_equal_approx(float(material.get_shader_parameter("window_lit_threshold")), 1.0), "daytime window threshold did not disable emission")

    if failures == 0:
        print("YARDMAN_BUILDING_NIGHT_TEST PASS clock=1 activity=1 renderer_budget=1 thermal=1 shader=1")
        quit()
    else:
        print("YARDMAN_BUILDING_NIGHT_TEST FAIL failures=%d" % failures)
        quit(1)
