extends SceneTree

const References = preload("res://scripts/reference_assets.gd")
const BetaRuntime = preload("res://scripts/beta_reference_asset_runtime.gd")
const TerrainShader = preload("res://shaders/terrain_surface.gdshader")
const WaterShader = preload("res://shaders/water.gdshader")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("BETA_REFERENCE_ASSET_CONTRACT_TEST: " + message)
    quit(1)

func _run() -> void:
    var upgrades: Dictionary = References.TEXTURE_UPGRADES
    if str(upgrades.get("ground_grass.png", "")) != "beta2_ucaptain_scrub_grass_albedo.ktx":
        _fail("Beta2 scrub-grass albedo semantic upgrade missing")
        return
    if str(upgrades.get("ground_rock.png", "")) != "beta2_ucaptain_mountain_terrain_albedo.ktx":
        _fail("Beta2 mountain terrain semantic upgrade missing")
        return
    if not References._valid_name("beta2_ucaptain_water_bump.ktx", PackedStringArray(["ktx"])):
        _fail("KTX source texture contract rejected")
        return

    var terrain_code := TerrainShader.code
    if not terrain_code.contains("reference_grass_normal") or not terrain_code.contains("has_reference_grass_normal"):
        _fail("terrain shader lacks optional recovered scrub normal contract")
        return
    var water_code := WaterShader.code
    if not water_code.contains("reference_normal") or not water_code.contains("has_reference_normal"):
        _fail("water shader lacks optional recovered WaterBump contract")
        return

    var contract := BetaRuntime.optional_asset_contract()
    if str(contract.get("terrain_normal", "")) != "beta2_ucaptain_scrub_grass_normal.ktx":
        _fail("terrain normal runtime filename drifted")
        return
    if str(contract.get("water_normal", "")) != "beta2_ucaptain_water_bump.ktx":
        _fail("water normal runtime filename drifted")
        return
    if bool(contract.get("geometry_mutation", true)) or bool(contract.get("collision", true)):
        _fail("reference quality layer gained geometry/collision authority")
        return
    if not bool(contract.get("asset_absent_fallback", false)):
        _fail("asset-absent fallback is not explicit")
        return

    # The public repository is allowed to omit private recovered media. Calling
    # the optional paths must remain safe whether those files are absent or a
    # private owner build stages them before import.
    References.texture("beta2_ucaptain_scrub_grass_normal.ktx")
    References.texture("beta2_ucaptain_water_bump.ktx")

    print("YARDMAN_BETA_REFERENCE_ASSET_CONTRACT_TEST PASS aliases=2 ktx=1 terrain_normal=1 water_normal=1 fallback=1")
    quit(0)
