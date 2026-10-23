extends SceneTree

const References = preload("res://scripts/reference_assets.gd")
const BetaRuntime = preload("res://scripts/beta_reference_asset_runtime.gd")
const DriverRuntime = preload("res://scripts/beta1_seated_driver_runtime.gd")
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
    if str(upgrades.get("ground_rock_alternate.png", "")) != "beta2_survival_rocks_diffuse.ktx":
        _fail("Beta2 survival-island alternate-rock semantic upgrade missing")
        return
    if not References._valid_name("beta2_ucaptain_water_bump.ktx", PackedStringArray(["ktx"])) \
            or not References._valid_name("beta2_survival_rocks_diffuse.ktx", PackedStringArray(["ktx"])):
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
    if not water_code.contains("reference_foam_alternate") or not water_code.contains("has_reference_foam_alternate") \
            or not water_code.contains("registered coast, shore-distance field, or sea-level mesh"):
        _fail("water shader lacks bounded alternate-foam contract")
        return
    var building_code := BuildingShader.code
    if not building_code.contains("reference_concrete") or not building_code.contains("has_reference_concrete") \
            or not building_code.contains("COLOR.a > 0.5 && COLOR.a < 0.7"):
        _fail("building shader lacks deterministic recovered concrete family")
        return
    if not building_code.contains("reference_stone_alternate") or not building_code.contains("has_reference_stone_alternate") \
            or not building_code.contains("One alternate sample only on stone-family wall fragments"):
        _fail("building shader lacks bounded alternate-stone contract")
        return
    if not building_code.contains("reference_stucco_natural") or not building_code.contains("has_reference_stucco_natural") \
            or not building_code.contains("painted_stucco_micro"):
        _fail("building shader lacks bounded natural-stucco microdetail")
        return
    if not building_code.contains("reference_stucco_red") or not building_code.contains("has_reference_stucco_red") \
            or not building_code.contains("reference_stucco_yellow") or not building_code.contains("has_reference_stucco_yellow"):
        _fail("building shader lacks recovered painted-stucco families")
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
    if str(contract.get("water_alt_foam", "")) != "water_foam_japan.png":
        _fail("alternate foam runtime filename drifted")
        return
    if int(contract.get("alternate_foam_extra_samples", 99)) != 1:
        _fail("alternate foam exceeded its one-sample shader budget")
        return
    if str(contract.get("building_concrete", "")) != "building_concrete.png":
        _fail("Beta1 concrete runtime filename drifted")
        return
    if str(contract.get("building_stone_alternate", "")) != "building_stonewall_04.png":
        _fail("Beta1 alternate-stone runtime filename drifted")
        return
    if int(contract.get("stone_alternate_extra_samples_per_fragment", 99)) != 1:
        _fail("alternate stone exceeded its one-sample stone-family budget")
        return
    if str(contract.get("building_stucco_natural", "")) != "building_stucco_natural.png":
        _fail("Beta1 natural-stucco runtime filename drifted")
        return
    if str(contract.get("building_stucco_red", "")) != "building_stucco_red.png" \
            or str(contract.get("building_stucco_yellow", "")) != "building_stucco_yellow.png":
        _fail("Beta1 painted-stucco runtime filenames drifted")
        return
    if int(contract.get("painted_stucco_extra_samples_per_fragment", 99)) != 1 \
            or bool(contract.get("palette_family_count_mutation", true)):
        _fail("painted stucco escaped its one-sample existing-palette budget")
        return
    if bool(contract.get("geometry_mutation", true)) or bool(contract.get("collision", true)) or bool(contract.get("extra_draw_calls", true)):
        _fail("reference quality layer gained geometry/collision/draw-call authority")
        return
    if not bool(contract.get("asset_absent_fallback", false)):
        _fail("asset-absent fallback is not explicit")
        return

    var driver_contract := DriverRuntime.asset_contract()
    if str(driver_contract.get("file", "")) != "road_driver_seated.glb":
        _fail("recovered seated-driver filename drifted")
        return
    var fit: Vector3 = driver_contract.get("fit_position_m", Vector3.INF)
    if fit.distance_to(Vector3(0.91, 0.21, -0.187)) > 0.000001:
        _fail("accepted RHD seated-driver fit position drifted")
        return
    if absf(float(driver_contract.get("fit_rotation_y_rad", 99.0))) > 0.000001 \
            or absf(float(driver_contract.get("fit_scale", 0.0)) - 1.0) > 0.000001:
        _fail("accepted seated-driver source rotation/scale changed")
        return
    if not bool(driver_contract.get("requires_reference_crown", false)) \
            or not bool(driver_contract.get("visible_when_occupied", false)) \
            or not bool(driver_contract.get("static_source_pose", false)):
        _fail("driver binding lost Crown/occupancy/static-pose constraints")
        return
    if bool(driver_contract.get("collision", true)) or bool(driver_contract.get("physics_mutation", true)) \
            or bool(driver_contract.get("handling_mutation", true)) or bool(driver_contract.get("fleet_mutation", true)):
        _fail("driver asset gained gameplay/physics authority")
        return
    if not bool(driver_contract.get("animation_retarget_pending", false)) \
            or not bool(driver_contract.get("android_acceptance_pending", false)) \
            or not bool(driver_contract.get("asset_absent_fallback", false)):
        _fail("driver contract makes unsupported animation/device/fallback claims")
        return

    var ancestor := Node3D.new()
    var identity_shell := Node3D.new()
    ancestor.add_child(identity_shell)
    if DriverRuntime.relative_pose(identity_shell, ancestor) != Transform3D.IDENTITY:
        ancestor.free()
        _fail("identity Crown shell pose is no longer accepted")
        return
    ancestor.free()

    var shell_pose := Transform3D(Basis(Vector3.UP, 0.31), Vector3(0.14, 0.06, -0.08))
    var local_pose := DriverRuntime.driver_local_pose(shell_pose, Basis.IDENTITY)
    var rebuilt := shell_pose * local_pose
    if rebuilt.origin.distance_to(Vector3(0.91, 0.21, -0.187)) > 0.000001:
        _fail("BodyShell-local conversion changed the measured RHD driver fit")
        return

    References.texture("beta2_ucaptain_scrub_grass_normal.ktx")
    References.texture("ground_rock_alternate.png")
    References.texture("beta2_survival_rocks_diffuse.ktx")
    References.texture("beta2_ucaptain_water_bump.ktx")
    References.texture("water_foam_japan.png")
    References.texture("building_concrete.png")
    References.texture("building_stonewall_04.png")
    References.texture("building_stucco_natural.png")
    References.texture("building_stucco_red.png")
    References.texture("building_stucco_yellow.png")
    References.scene("road_driver_seated.glb")

    # Preserve the established marker consumed by the reconciliation workflow;
    # newer assertions above extend the contract without weakening it.
    print("YARDMAN_BETA_REFERENCE_ASSET_CONTRACT_TEST PASS aliases=2 ktx=1 terrain_normal=1 water_normal=1 concrete=1 fallback=1")
    quit(0)
