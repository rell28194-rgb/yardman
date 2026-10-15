extends SceneTree

const References = preload("res://scripts/reference_assets.gd")
const Roads = preload("res://scripts/road_streamer.gd")
const Visuals = preload("res://scripts/world_visuals.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("REFERENCE_ASSETS_TEST: " + message)

func _run() -> void:
    _check(References.texture("../outside.png") == null, "Path traversal accepted")
    _check(References.scene("script.gd") == null, "Executable reference script accepted")
    _check(References.audio("folder/sample.wav") == null, "Nested path accepted")
    _check(str(References.TEXTURE_UPGRADES.get("ground_dry_grass.png", "")) == "beta2_ucaptain_mountain_terrain_albedo.ktx",
        "Beta2 vegetated mountain surface must occupy the dry grass/earth slot")
    _check(str(References.TEXTURE_UPGRADES.get("ground_rock.png", "")) == "ground_rock_alternate.png",
        "Exposed rock must select the approved snow-free rock source")
    _check("ground_rock.png" in References.STRICT_TEXTURE_UPGRADES,
        "Missing dry rock must fall back procedurally, never to the snowy original")
    if not ResourceLoader.exists(References.ROOT + "ground_rock_alternate.png"):
        _check(References.texture("ground_rock.png") == null,
            "Missing approved dry rock incorrectly loaded the snowy original")
    _check(str(References.TEXTURE_UPGRADES.get("ground_grass.png", "")) == "beta2_ucaptain_scrub_grass_albedo.ktx",
        "Beta2 scrub-grass texture upgrade mapping changed")
    # These methods are part of main.gd's live streaming/quality contract and
    # must exist even when CI runs without the private reference pack.
    var visuals := Visuals.new()
    _check(visuals.has_method("make_roadside"), "World visuals lost roadside generation")
    _check(visuals.has_method("apply_roadside_quality"), "World visuals lost roadside quality control")
    var manifest: Dictionary = References.manifest()
    var required := OS.get_environment("YARDMAN_REQUIRE_REFERENCE") == "1"
    if manifest.is_empty():
        _check(not required, "Required personal asset manifest missing")
        _check(References.texture("road_asphalt.png") == null, "Missing pack supplied a texture")
        print("YARDMAN_REFERENCE_ASSETS_TEST %s private_pack=0 fallback=1 roadside_api=1" % ("PASS" if failures == 0 else "FAIL"))
        quit(failures)
        return
    var verified := 0
    var textures := 0
    var ktx_textures := 0
    for record: Dictionary in manifest.get("files", []):
        var filename: String = str(record.get("path", ""))
        _check(not filename.contains("/") and not filename.contains(".."), "Manifest path escapes pack")
        var path: String = References.ROOT + filename
        _check(FileAccess.file_exists(path), "Manifest file missing: " + filename)
        if not FileAccess.file_exists(path):
            continue
        var expected: String = str(record.get("sha256", ""))
        _check(expected.length() == 64 and FileAccess.get_sha256(path) == expected, "File hash mismatch: " + filename)
        verified += 1
        if filename.ends_with(".png") or filename.ends_with(".ktx"):
            var texture: Texture2D = References.texture(filename)
            _check(texture != null, "Texture failed to import: " + filename)
            if texture != null:
                _check(texture.get_width() >= 64 and texture.get_height() >= 64, "Texture unexpectedly tiny: " + filename)
                var image: Image = texture.get_image()
                _check(image != null and image.has_mipmaps(), "Texture lacks mobile mipmaps: " + filename)
                textures += 1
                if filename.ends_with(".ktx"):
                    ktx_textures += 1
    _check(verified >= 9 and textures >= 8, "Private pack is incomplete")
    var roads := Roads.new()
    roads._make_materials()
    _check(roads._asphalt_material.get_shader_parameter("has_reference_albedo") == true, "Asphalt reference not active")
    _check(roads._dirt_material.get_shader_parameter("has_reference_albedo") == true, "Gravel reference not active")
    var material_a: ShaderMaterial = visuals.terrain_material(Vector2.ZERO)
    var material_b: ShaderMaterial = visuals.terrain_material(Vector2(4096.0, 0.0))
    _check(material_a.get_shader_parameter("has_reference_ground") == true, "Ground references not active")
    _check(material_a.get_shader_parameter("reference_grass") == material_b.get_shader_parameter("reference_grass"), "Tiles duplicate reference textures")
    if required:
        _check(References.scene("road_car.glb") != null, "Required reference sedan missing")
        _check(References.texture("beta2_ucaptain_water_bump.ktx") != null, "Recovered Beta2 water normal missing")
        var direct_mountain := References.texture("beta2_ucaptain_mountain_terrain_albedo.ktx")
        _check(direct_mountain != null, "Recovered Beta2 mountain terrain missing")
        _check(References.texture("ground_dry_grass.png") == direct_mountain,
            "Dry grass/earth semantic alias did not select recovered Beta2 mountain source")
        var exposed_rock := References.texture("ground_rock.png")
        _check(exposed_rock != null and exposed_rock != direct_mountain,
            "Exposed rock must remain distinct from vegetated mountain earth")
        _check(exposed_rock == References.texture("ground_rock_alternate.png"),
            "Exposed rock must bind the approved alternate directly")
        _check(exposed_rock != null and exposed_rock.resource_path.ends_with("/ground_rock_alternate.png"),
            "Exposed-rock binding did not select the approved dry-rock source")
        _check(material_a.get_shader_parameter("reference_dry_grass") == direct_mountain,
            "Terrain did not bind recovered mountain earth as dry ground")
        _check(material_a.get_shader_parameter("reference_rock") == exposed_rock,
            "Terrain did not preserve the separate exposed-rock material")
        var direct_grass := References.texture("beta2_ucaptain_scrub_grass_albedo.ktx")
        _check(direct_grass != null, "Recovered Beta2 scrub grass missing")
        _check(References.texture("ground_grass.png") == direct_grass,
            "Terrain semantic alias did not select recovered Beta2 scrub grass source")
        var direct_grass_normal := References.texture("beta2_ucaptain_scrub_grass_normal.ktx")
        _check(direct_grass_normal != null, "Recovered Beta2 scrub-grass normal missing")
        _check(material_a.get_shader_parameter("has_reference_grass_normal") == true,
            "Recovered scrub-grass normal was not enabled on terrain")
        _check(material_a.get_shader_parameter("reference_grass_normal") == direct_grass_normal,
            "Terrain material did not bind the recovered scrub-grass normal")
        _check(ktx_textures >= 4, "Expected recovered Beta2 KTX textures were not imported")
    roads.free()
    print("YARDMAN_REFERENCE_ASSETS_TEST %s private_pack=1 verified=%d textures=%d ktx=%d materials=1 mipmaps=1 roadside_api=1" % [
        "PASS" if failures == 0 else "FAIL", verified, textures, ktx_textures])
    quit(failures)
