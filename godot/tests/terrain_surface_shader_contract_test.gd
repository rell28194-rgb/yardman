extends SceneTree

const SHADER_PATH := "res://shaders/terrain_surface.gdshader"
const BetaRuntime = preload("res://scripts/beta_reference_asset_runtime.gd")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("TERRAIN_SURFACE_SHADER_CONTRACT_TEST: " + message)
    quit(1)

func _run() -> void:
    if not FileAccess.file_exists(SHADER_PATH):
        _fail("terrain shader missing")
        return
    var code := FileAccess.get_file_as_string(SHADER_PATH)
    for required in [
        "vec2 uv_warp",
        "vec3 macro_patch",
        "float family_scale",
        "float moisture",
        "float pale_rock",
        "surface_hd_lush",
        "weather_wetness",
        "tunnel_portal_mask",
        "reference_soil_detail",
        "has_reference_soil_detail",
        "one top-projected sample only",
        "bare-soil mask still decides",
    ]:
        if code.find(required) < 0:
            _fail("missing material contract token: " + required)
            return
    if code.count("texture(reference_soil_detail") != 1:
        _fail("recovered survival soil exceeded one source sample")
        return
    var beta_contract := BetaRuntime.optional_asset_contract()
    if str(beta_contract.get("terrain_soil_detail", "")) != "beta2_survival_woodsground_diffuse.ktx" \
            or int(beta_contract.get("soil_detail_extra_samples", 99)) != 1:
        _fail("survival-island soil runtime contract drifted")
        return
    if bool(beta_contract.get("geometry_mutation", true)) or bool(beta_contract.get("collision", true)) \
            or bool(beta_contract.get("extra_draw_calls", true)):
        _fail("soil presentation gained geometry/collision/draw-call authority")
        return
    if code.find("mix(vec3(grass_luma), grass, 0.82) * 0.88") >= 0:
        _fail("legacy global grass desaturation is still active")
        return
    var shader := load(SHADER_PATH) as Shader
    if shader == null:
        _fail("Godot could not load terrain shader")
        return
    var material := ShaderMaterial.new()
    material.shader = shader
    if material.shader == null:
        _fail("terrain shader could not bind to ShaderMaterial")
        return
    print("YARDMAN_TERRAIN_SURFACE_SHADER_CONTRACT_TEST PASS warp=1 scale=1 biome=1 pale_rock=1 hd=1 weather=1 tunnel=1")
    quit(0)
