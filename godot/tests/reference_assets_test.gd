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
    var manifest: Dictionary = References.manifest()
    var required := OS.get_environment("YARDMAN_REQUIRE_REFERENCE") == "1"
    if manifest.is_empty():
        _check(not required, "Required personal asset manifest missing")
        _check(References.texture("road_asphalt.png") == null, "Missing pack supplied a texture")
        print("YARDMAN_REFERENCE_ASSETS_TEST %s private_pack=0 fallback=1" % ("PASS" if failures == 0 else "FAIL"))
        quit(failures)
        return
    var verified := 0
    var textures := 0
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
        if filename.ends_with(".png"):
            var texture: Texture2D = References.texture(filename)
            _check(texture != null, "Texture failed to import: " + filename)
            if texture != null:
                var image: Image = texture.get_image()
                _check(image != null and image.has_mipmaps(), "Texture lacks mobile mipmaps: " + filename)
                _check(texture.get_width() >= 64 and texture.get_height() >= 64, "Texture unexpectedly tiny: " + filename)
                textures += 1
    _check(verified >= 9 and textures >= 8, "Private pack is incomplete")
    var roads := Roads.new()
    roads._make_materials()
    _check(roads._asphalt_material.get_shader_parameter("has_reference_albedo") == true, "Asphalt reference not active")
    _check(roads._dirt_material.get_shader_parameter("has_reference_albedo") == true, "Gravel reference not active")
    var visuals := Visuals.new()
    var material_a: ShaderMaterial = visuals.terrain_material(Vector2.ZERO)
    var material_b: ShaderMaterial = visuals.terrain_material(Vector2(4096.0, 0.0))
    _check(material_a.get_shader_parameter("has_reference_ground") == true, "Ground references not active")
    _check(material_a.get_shader_parameter("reference_grass") == material_b.get_shader_parameter("reference_grass"), "Tiles duplicate reference textures")
    if required:
        _check(References.scene("road_car.glb") != null, "Required reference sedan missing")
    roads.free()
    print("YARDMAN_REFERENCE_ASSETS_TEST %s private_pack=1 verified=%d textures=%d materials=1 mipmaps=1" % ["PASS" if failures == 0 else "FAIL", verified, textures])
    quit(failures)
