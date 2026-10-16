extends SceneTree

# Actual-render private-media gate. Generated ground/cliff geometry isolates
# material recovery; no source-game terrain or replacement geography is used.
# Each A/B/control set renders simultaneously under identical light and coords.
const Visuals = preload("res://scripts/world_visuals.gd")
const References = preload("res://scripts/reference_assets.gd")
const Registry = preload("res://scripts/render_material_registry.gd")
const SIZE := Vector2i(640, 400)
const ORIGIN := Vector2(-32768.0, 8192.0)
const SOURCES := ["beta2_ucaptain_scrub_grass_albedo.ktx",
    "beta2_ucaptain_mountain_terrain_albedo.ktx", "beta2_ucaptain_scrub_grass_normal.ktx"]

class TerrainFixture:
    extends Node3D
    var _loaded: Dictionary = {}
    var _far_root: Node3D

class SceneFixture:
    extends Node3D
    var terrain: TerrainFixture
    var roads: Node

var failures := 0
var output_dir := ""
var report: Dictionary = {}
var material: ShaderMaterial
var source_textures: Array[Texture2D] = []
var exposed_rock: Texture2D
var original_grass: Texture2D
var original_dry_grass: Texture2D
var rejected_snow_rock: Texture2D

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("RECOVERED_TERRAIN_RENDER_TEST: " + message)

func _mesh(cliff: bool) -> ArrayMesh:
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var tangents := PackedFloat32Array()
    var uv := PackedVector2Array()
    var half_z := 3.0 if cliff else 10.0
    var corners := [Vector2(-10, -half_z), Vector2(10, -half_z), Vector2(10, half_z), Vector2(-10, half_z)]
    var coordinates := [Vector2.ZERO, Vector2.RIGHT, Vector2.ONE, Vector2.DOWN]
    var normal := Vector3(0, 1, 3).normalized() if cliff else Vector3.UP
    for index in [0, 1, 2, 0, 2, 3]:
        var point: Vector2 = corners[index]
        vertices.append(Vector3(point.x, -3.0 * point.y if cliff else 0.0, point.y))
        normals.append(normal)
        tangents.append_array(PackedFloat32Array([1, 0, 0, 1]))
        uv.append(coordinates[index])
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = normals
    arrays[Mesh.ARRAY_TANGENT] = tangents
    arrays[Mesh.ARRAY_TEX_UV] = uv
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    return mesh

func _viewport(selected: ShaderMaterial, cliff: bool, detail: bool = false) -> SubViewport:
    var viewport := SubViewport.new()
    viewport.size = SIZE
    viewport.own_world_3d = true
    viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
    root.add_child(viewport)
    var environment := WorldEnvironment.new()
    var settings := Environment.new()
    settings.background_mode = Environment.BG_COLOR
    settings.background_color = Color(0.12, 0.18, 0.24)
    settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    settings.ambient_light_color = Color(0.72, 0.80, 0.90)
    settings.ambient_light_energy = 0.08 if detail else 0.35
    settings.tonemap_mode = Environment.TONE_MAPPER_LINEAR
    environment.environment = settings
    viewport.add_child(environment)
    var sun := DirectionalLight3D.new()
    sun.rotation_degrees = Vector3(-12.0 if detail else -25.0, -28.0, 0.0)
    sun.light_energy = 2.5 if detail else 1.1
    viewport.add_child(sun)
    var camera := Camera3D.new()
    camera.position = Vector3(1, 2, 3) if detail else Vector3(8, 11, 18)
    camera.projection = Camera3D.PROJECTION_ORTHOGONAL
    # Normal contribution is a close-range material feature: distant mip
    # averages correctly remove fine grass detail. Albedo uses the wider view.
    camera.size = 4.0 if detail else 25.0
    viewport.add_child(camera)
    camera.look_at(Vector3.ZERO)
    camera.current = true
    var ground := MeshInstance3D.new()
    ground.mesh = _mesh(cliff)
    ground.material_override = selected
    viewport.add_child(ground)
    return viewport

func _difference(a: Image, b: Image) -> Dictionary:
    var total := 0.0
    var changed := 0
    var count := 0
    var maximum := 0.0
    for y in range(0, SIZE.y, 2):
        for x in range(0, SIZE.x, 2):
            var ca := a.get_pixel(x, y)
            var cb := b.get_pixel(x, y)
            var error := (absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)) / 3.0
            total += error
            maximum = maxf(maximum, error)
            changed += int(error > 1.0 / 255.0)
            count += 1
    return {"mean_absolute_rgb": total / count, "maximum_rgb": maximum,
        "changed_fraction_over_1_byte": float(changed) / count, "sampled_pixels": count}

func _capture(label: String, contribution: String) -> void:
    var cliff := contribution == "exposed-rock-role"
    var recovered := material.duplicate() as ShaderMaterial
    var fallback := material.duplicate() as ShaderMaterial
    if contribution == "grass-albedo":
        fallback.set_shader_parameter("reference_grass", original_grass)
    elif contribution == "soil-albedo":
        fallback.set_shader_parameter("reference_dry_grass", original_dry_grass)
    elif contribution == "exposed-rock-role":
        # Reproduce the rejected original snow-covered rock. The production
        # loader binds the authorized dry-rock alternate or falls back safely.
        fallback.set_shader_parameter("reference_rock", rejected_snow_rock)
    else:
        fallback.set_shader_parameter("has_reference_grass_normal", false)
    var detail := contribution == "grass-normal"
    var left := _viewport(recovered, cliff, detail)
    var right := _viewport(fallback, cliff, detail)
    var identical := _viewport(recovered, cliff, detail)
    for frame in range(10):
        await process_frame
    await RenderingServer.frame_post_draw
    var a := left.get_texture().get_image()
    var b := right.get_texture().get_image()
    var c := identical.get_texture().get_image()
    _check(a != null and b != null and c != null, label + ": no actual renderer image")
    if a == null or b == null or c == null:
        return
    var metrics := _difference(a, b)
    var control := _difference(a, c)
    _check(float(control.mean_absolute_rgb) < 0.00001, label + ": identical source controls differ")
    _check(float(metrics.mean_absolute_rgb) > 0.0001, label + ": source contribution is not visible")
    _check(float(metrics.changed_fraction_over_1_byte) > 0.01, label + ": fewer than one percent of pixels visibly changed")
    _check(a.save_png(output_dir.path_join(label + "-recovered.png")) == OK, "Cannot save recovered capture")
    _check(b.save_png(output_dir.path_join(label + "-fallback.png")) == OK, "Cannot save fallback capture")
    report["captures"].append({"label": label, "contribution": contribution,
        "shader": material.shader.resource_path, "difference": metrics, "identical_control_difference": control,
        "view_size_m": 4.0 if detail else 25.0,
        "sun_energy": 2.5 if detail else 1.1,
        "comparison": "approved dry rock versus rejected snow-covered original" if cliff else "only named source contribution changed",
        "recovered_image": label + "-recovered.png", "fallback_image": label + "-fallback.png"})
    for viewport in [left, right, identical]:
        viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
        viewport.queue_free()
    await process_frame

func _bindings(label: String) -> void:
    for index in range(3):
        var parameter: String = ["reference_grass", "reference_dry_grass", "reference_grass_normal"][index]
        _check(material.get_shader_parameter(parameter) == source_textures[index], label + ": source texture lost: " + parameter)
    _check(material.get_shader_parameter("reference_rock") == exposed_rock,
        label + ": approved dry-rock binding changed")
    _check(exposed_rock != source_textures[1], label + ": exposed rock reused vegetated mountain earth")
    for flag in ["has_reference_ground", "has_reference_rock", "has_reference_grass_normal"]:
        _check(material.get_shader_parameter(flag) == true, label + ": source flag lost: " + flag)
    _check(material.get_shader_parameter("tile_origin") == ORIGIN, label + ": canonical material origin changed")

func _run() -> void:
    if DisplayServer.get_name() == "headless":
        _check(false, "Actual display required; headless cannot validate recovered terrain")
        quit(1)
        return
    await process_frame
    paused = false
    for child in root.get_children():
        child.process_mode = Node.PROCESS_MODE_DISABLED
    for canvas in root.find_children("*", "CanvasLayer", true, false):
        canvas.visible = false
    var actual := RenderingServer.get_current_rendering_method()
    _check(actual == OS.get_environment("YARDMAN_EXPECT_RENDER_METHOD"), "Unexpected renderer fallback: " + actual)
    output_dir = OS.get_environment("YARDMAN_TERRAIN_CAPTURE_DIR")
    _check(not output_dir.is_empty(), "YARDMAN_TERRAIN_CAPTURE_DIR is required")
    if output_dir.is_empty():
        quit(1)
        return
    _check(DirAccess.make_dir_recursive_absolute(output_dir) == OK, "Cannot create evidence directory")
    var sources: Array = []
    for name: String in SOURCES:
        var texture: Texture2D = References.texture(name)
        _check(texture != null, "Required source missing: " + name)
        if texture == null:
            quit(1)
            return
        source_textures.append(texture)
        var source := FileAccess.open(References.ROOT + name, FileAccess.READ)
        var levels := 0
        if source != null:
            source.seek(56)
            levels = source.get_32()
            source.close()
        _check(levels == 10, "Original KTX ten-level mip chain missing: " + name)
        _check(texture.get_size() == Vector2(512, 512), "Unexpected texture dimensions: " + name)
        sources.append({"name": name, "width": texture.get_width(), "height": texture.get_height(), "original_ktx_mip_levels": levels})
    _check(References.texture("ground_grass.png") == source_textures[0], "Grass alias did not choose direct KTX upgrade")
    _check(References.texture("ground_dry_grass.png") == source_textures[1], "Dry grass/earth alias did not choose direct KTX upgrade")
    exposed_rock = References.texture("ground_rock.png")
    _check(exposed_rock != null and exposed_rock != source_textures[1], "Exposed rock must remain distinct from vegetated terrain")
    _check(exposed_rock == References.texture("ground_rock_alternate.png"), "Rock alias did not choose the approved alternate")
    _check(exposed_rock != null and exposed_rock.resource_path.ends_with("/ground_rock_alternate.png"), "Approved dry rock source was not selected")
    original_grass = ResourceLoader.load(References.ROOT + "ground_grass.png") as Texture2D
    original_dry_grass = ResourceLoader.load(References.ROOT + "ground_dry_grass.png") as Texture2D
    rejected_snow_rock = ResourceLoader.load(References.ROOT + "ground_rock.png") as Texture2D
    _check(original_grass != null and original_dry_grass != null and rejected_snow_rock != null, "Original diagnostic controls are required")
    if exposed_rock == null or original_grass == null or original_dry_grass == null or rejected_snow_rock == null:
        quit(1)
        return
    var visuals := Visuals.new()
    material = visuals.terrain_material(ORIGIN)
    report = {"engine": Engine.get_version_info(), "method": actual,
        "adapter": RenderingServer.get_video_adapter_name(), "sources": sources,
        "canonical_origin": [ORIGIN.x, ORIGIN.y], "captures": [],
        "scope": "Actual software host GLES/Vulkan material tests on generated geometry; not Android device, source-world geography or national deployment acceptance."}
    var fixture := SceneFixture.new()
    fixture.terrain = TerrainFixture.new()
    fixture.add_child(fixture.terrain)
    var tile := MeshInstance3D.new()
    tile.mesh = _mesh(false)
    tile.material_override = material
    fixture.terrain.add_child(tile)
    fixture.terrain._loaded["fixture"] = tile
    root.add_child(fixture)
    var runtime := root.get_node("RenderRuntime")
    for step in [{"label": "high-before", "quality": "Quality", "terrain_variant": "3layer"},
            {"label": "safe", "quality": "Performance", "terrain_variant": "2layer"},
            {"label": "high-restored", "quality": "Quality", "terrain_variant": "3layer"}]:
        step["renderer"] = "vulkan_mobile"
        runtime.apply_streamer_material_policy(fixture, step)
        _bindings(str(step.label))
        var expected: Shader = Registry.TERRAIN_SAFE if str(step.terrain_variant) == "2layer" else Registry.TERRAIN_HIGH
        _check(material.shader == expected, str(step.label) + ": live material did not change to requested shader")
        for contribution in ["grass-albedo", "soil-albedo", "grass-normal", "exposed-rock-role"]:
            await _capture(str(step.label) + "-" + contribution, contribution)
    for contribution in ["grass-albedo", "soil-albedo", "grass-normal", "exposed-rock-role"]:
        var before := Image.load_from_file(output_dir.path_join("high-before-" + contribution + "-recovered.png"))
        var restored := Image.load_from_file(output_dir.path_join("high-restored-" + contribution + "-recovered.png"))
        var restored_difference := _difference(before, restored)
        _check(float(restored_difference.mean_absolute_rgb) == 0.0,
            contribution + ": returning to high tier changed the image despite identical coordinates and source")
    report["failures"] = failures
    var handle := FileAccess.open(output_dir.path_join("recovered-terrain-report.json"), FileAccess.WRITE)
    if handle != null:
        handle.store_string(JSON.stringify(report, "  ") + "\n")
        handle.close()
    else:
        _check(false, "Cannot save report")
    fixture.queue_free()
    await process_frame
    print("YARDMAN_RECOVERED_TERRAIN_RENDER_TEST %s method=%s pairs=%d failures=%d" % ["PASS" if failures == 0 else "FAIL", actual, report.captures.size(), failures])
    quit(0 if failures == 0 else 1)
