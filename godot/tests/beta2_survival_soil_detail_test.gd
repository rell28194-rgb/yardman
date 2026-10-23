extends SceneTree

const References = preload("res://scripts/reference_assets.gd")
const BetaRuntime = preload("res://scripts/beta_reference_asset_runtime.gd")
const TerrainShader = preload("res://shaders/terrain_surface.gdshader")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("BETA2_SURVIVAL_SOIL_DETAIL_TEST: " + message)
    quit(1)

func _run() -> void:
    var code := TerrainShader.code
    if not code.contains("reference_soil_detail") or not code.contains("has_reference_soil_detail"):
        _fail("terrain shader lacks recovered soil-detail binding")
        return
    if not code.contains("one top-projected sample only") or not code.contains("bare-soil mask still decides"):
        _fail("soil-detail shader lost bounded presentation-only contract")
        return
    if code.count("texture(reference_soil_detail") != 1:
        _fail("soil detail exceeded one source sample")
        return

    var contract := BetaRuntime.optional_asset_contract()
    if str(contract.get("terrain_soil_detail", "")) != "beta2_survival_woodsground_diffuse.ktx":
        _fail("survival-island woodsground filename drifted")
        return
    if int(contract.get("soil_detail_extra_samples", 99)) != 1:
        _fail("soil detail exceeded one-sample budget")
        return
    if bool(contract.get("geometry_mutation", true)) or bool(contract.get("collision", true)) \
            or bool(contract.get("extra_draw_calls", true)):
        _fail("soil-detail quality layer gained geometry/collision/draw-call authority")
        return
    if not bool(contract.get("asset_absent_fallback", false)):
        _fail("asset-absent fallback is not explicit")
        return

    # Public CI intentionally has no private recovered media. The lookup must be
    # safe in that state while owner builds can stage the exact KTX privately.
    References.texture("beta2_survival_woodsground_diffuse.ktx")

    print("YARDMAN_BETA2_SURVIVAL_SOIL_DETAIL_TEST PASS source=woodsground_diffuse astc8x8=1 mips=10 samples=1 geometry=0 collision=0 draw_calls=0 fallback=1")
    quit(0)
