extends SceneTree

const References = preload("res://scripts/reference_assets.gd")
const BetaRuntime = preload("res://scripts/beta_reference_asset_runtime.gd")
const TerrainShader = preload("res://shaders/terrain_surface.gdshader")
const WaterShader = preload("res://shaders/water.gdshader")
const BuildingShader = preload("res://shaders/building_surface.gdshader")

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
    if not terrain_code.contains("reference_rock_alternate") or not terrain_code.contains("has_reference_rock_alternate") \
            or not terrain_code.contains("dominant-axis lookup"):
        _fail("terrain shader lacks bounded alternate-rock contract")
        return
    var water_code := WaterShader.code
    if not water_code.contains("reference_normal") or not water_code.contains("has_reference_normal"):
        _fail("water shader lacks optional recovered WaterBump contract")
        return
    var building_code := BuildingShader.code
    if not building_code.contains("reference_concrete") or not building_code.contains("has_reference_concrete") \
            or not building_code.contains("COLOR.a > 0.5 && COLOR.a < 0.7"):
        _fail("building shader lacks deterministic recovered concrete family")
        return

    var contract := BetaRuntime.optional_asset_contract()
    if str(contract.get("terrain_normal", "")) != "beta2_ucaptain_scrub_grass_normal.ktx":
        _fail("terrain normal runtime filename drifted")
        return
    if str(contract.get("terrain_alt_rock", "")) != "ground_rock_alternate.png":
        _fail("alternate rock runtime filename drifted")
        return
    if int(contract.get("alternate_rock_extra_samples", 99)) != 1:
        _fail("alternate rock exceeded its one-sample shader budget")
        return
    if str(contract.get("water_normal", "")) != "beta2_ucaptain_water_bump.ktx":
        _fail("water normal runtime filename drifted")
        return
    if str(contract.get("building_concrete", "")) != "building_concrete.png":
        _fail("Beta1 concrete runtime filename drifted")
        return
    if bool(contract.get("geometry_mutation", true)) or bool(contract.get("collision", true)) or bool(contract.get("extra_draw_calls", true)):
        _fail("reference quality layer gained geometry/collision/draw-call authority")
        return
    if not bool(contract.get("asset_absent_fallback", false)):
        _fail("asset-absent fallback is not explicit")
        return

    References.texture("beta2_ucaptain_scrub_grass_normal.ktx")
    References.texture("ground_rock_alternate.png")
    References.texture("beta2_ucaptain_water_bump.ktx")
    References.texture("building_concrete.png")

    print("YARDMAN_BETA_REFERENCE_ASSET_CONTRACT_TEST PASS aliases=2 ktx=1 terrain_normal=1 alt_rock=1 water_normal=1 concrete=1 fallback=1")
    quit(0)
