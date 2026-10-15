extends SceneTree

# Private-media integration test. A real display and the recovered KTX are
# required: asset-absent headless tests cannot establish visible integration.
# Paired viewports render at the same shader TIME, isolating source-normal
# contribution from animated waves, camera, lighting and exposure changes.
const Coastline = preload("res://scripts/coastline.gd")
const ReferenceAssets = preload("res://scripts/reference_assets.gd")
const SIZE := Vector2i(640, 400)
var failures := 0
var output_dir := ""
var report: Dictionary = {}
var worlds: Array[SubViewport] = []

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("RECOVERED_WATER_RENDER_TEST: " + message)

func _viewport(material: ShaderMaterial) -> SubViewport:
    var viewport := SubViewport.new()
    viewport.size = SIZE
    viewport.own_world_3d = true
    viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
    root.add_child(viewport)
    worlds.append(viewport)
    var environment := WorldEnvironment.new()
    var settings := Environment.new()
    settings.background_mode = Environment.BG_COLOR
    settings.background_color = Color(0.18, 0.29, 0.39)
    settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    settings.ambient_light_color = Color(0.66, 0.76, 0.87)
    settings.ambient_light_energy = 0.40
    settings.tonemap_mode = Environment.TONE_MAPPER_LINEAR
    environment.environment = settings
    viewport.add_child(environment)
    var sun := DirectionalLight3D.new()
    # Grazing sunlight reveals the water normal response in the reflected lobe.
    sun.rotation_degrees = Vector3(-18.0, -148.0, 0.0)
    sun.light_energy = 2.0
    viewport.add_child(sun)
    var camera := Camera3D.new()
    camera.position = Vector3(15.0, 9.0, 20.0)
    camera.fov = 48.0
    viewport.add_child(camera)
    camera.look_at(Vector3(0.0, 0.0, -4.0))
    camera.current = true
    var coast = Coastline.new()
    coast.water_material = material
    viewport.add_child(coast)
    # Generated test rectangle, metres. No recovered map/shoreline is used.
    var vertices := PackedVector3Array([
        Vector3(-24, 0, -32), Vector3(24, 0, -32), Vector3(24, 0, 20),
        Vector3(-24, 0, -32), Vector3(24, 0, 20), Vector3(-24, 0, 20),
    ])
    var distances := PackedFloat32Array([40, 40, 1, 40, 1, 1])
    coast.append_water({"water": vertices, "shore_distance": distances}, coast, 0, 0)
    return viewport

func _difference(a: Image, b: Image) -> Dictionary:
    var absolute_error := 0.0
    var maximum := 0.0
    var changed := 0
    var count := 0
    for y in range(0, SIZE.y, 2):
        for x in range(0, SIZE.x, 2):
            var ca := a.get_pixel(x, y)
            var cb := b.get_pixel(x, y)
            var error := (absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)) / 3.0
            absolute_error += error
            maximum = maxf(maximum, error)
            if error > 1.0 / 255.0:
                changed += 1
            count += 1
    return {"mean_absolute_rgb": absolute_error / count, "maximum_rgb": maximum,
        "changed_fraction_over_1_byte": float(changed) / count, "sampled_pixels": count}

func _capture_pair(label: String, material: ShaderMaterial) -> void:
    var recovered := material.duplicate() as ShaderMaterial
    var fallback := material.duplicate() as ShaderMaterial
    # All other optional media stay identical. Only the recovered normal differs.
    fallback.set_shader_parameter("has_reference_normal", false)
    var left := _viewport(recovered)
    var right := _viewport(fallback)
    var control := _viewport(recovered)
    for frame in range(10):
        await process_frame
    await RenderingServer.frame_post_draw
    var a := left.get_texture().get_image()
    var b := right.get_texture().get_image()
    var c := control.get_texture().get_image()
    _check(a != null and b != null and c != null, label + ": renderer produced no image")
    if a == null or b == null or c == null:
        return
    _check(not a.is_empty() and a.get_size() == SIZE, label + ": invalid capture size")
    var metrics := _difference(a, b)
    var control_metrics := _difference(a, c)
    _check(float(control_metrics.mean_absolute_rgb) < 0.00001,
        label + ": identical recovered controls differ; A/B is not isolated")
    _check(float(metrics.mean_absolute_rgb) > 0.0001,
        label + ": recovered water normal has no measurable visible effect")
    _check(float(metrics.changed_fraction_over_1_byte) > 0.01,
        label + ": normal contribution affects fewer than one percent of pixels")
    _check(a.save_png(output_dir.path_join(label + "-recovered.png")) == OK, "Could not save recovered capture")
    _check(b.save_png(output_dir.path_join(label + "-fallback.png")) == OK, "Could not save fallback capture")
    report["captures"].append({"label": label, "shader": material.shader.resource_path,
        "recovered_image": label + "-recovered.png", "fallback_image": label + "-fallback.png",
        "difference": metrics, "identical_control_difference": control_metrics})
    for viewport in [left, right, control]:
        viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
        worlds.erase(viewport)
        viewport.queue_free()
    await process_frame

func _run() -> void:
    if DisplayServer.get_name() == "headless":
        _check(false, "An actual display is required")
        quit(1)
        return
    await process_frame
    paused = false
    for child in root.get_children():
        child.process_mode = Node.PROCESS_MODE_DISABLED
    for canvas in root.find_children("*", "CanvasLayer", true, false):
        canvas.visible = false
    var actual := RenderingServer.get_current_rendering_method()
    _check(actual == OS.get_environment("YARDMAN_EXPECT_RENDER_METHOD"), "Unexpected renderer/fallback: " + actual)
    output_dir = OS.get_environment("YARDMAN_WATER_CAPTURE_DIR")
    _check(not output_dir.is_empty(), "YARDMAN_WATER_CAPTURE_DIR is required")
    if output_dir.is_empty():
        quit(1)
        return
    _check(DirAccess.make_dir_recursive_absolute(output_dir) == OK, "Cannot create capture directory")
    var texture: Texture2D = ReferenceAssets.texture("beta2_ucaptain_water_bump.ktx")
    _check(texture != null, "Recovered uCaptain KTX is required; missing media cannot pass")
    if texture == null:
        quit(1)
        return
    _check(texture.get_size() == Vector2(512, 512), "Unexpected recovered source dimensions")
    # Inspect the installed original KTX, avoiding compressed GPU texture
    # readback, which is unsupported on some otherwise valid Vulkan drivers.
    var source_file := FileAccess.open(ReferenceAssets.ROOT + "beta2_ucaptain_water_bump.ktx", FileAccess.READ)
    var source_levels := 0
    if source_file != null:
        source_file.seek(56) # KTX1 numberOfMipmapLevels, little-endian source.
        source_levels = source_file.get_32()
        source_file.close()
    _check(source_levels == 10, "Installed recovered KTX must preserve all ten original mip levels")
    report = {"engine": Engine.get_version_info(), "method": actual,
        "adapter": RenderingServer.get_video_adapter_name(), "display": DisplayServer.get_name(),
        "source_name": "beta2_ucaptain_water_bump.ktx", "source_dimensions": [texture.get_width(), texture.get_height()],
        "installed_ktx_mip_levels_including_base": source_levels,
        "captures": [], "scope": "Actual host/software renderer, generated geometry, recovered production material. Not Android-device, geographic or national deployment acceptance."}
    var coast = Coastline.new()
    root.add_child(coast)
    for step in [{"label": "high-before", "quality": "Quality", "water_variant": "dual_normal"},
            {"label": "safe", "quality": "Performance", "water_variant": "opaque"},
            {"label": "high-restored", "quality": "Quality", "water_variant": "dual_normal"}]:
        # Exercise both production shader variants on each real backend.
        # Normal GLES runtime remains on its independently tested safe variant.
        coast.apply_render_policy(step, "vulkan_mobile")
        _check(coast.water_material.get_shader_parameter("has_reference_normal") == true, str(step.label) + ": source flag lost during variant switch")
        _check(coast.water_material.get_shader_parameter("reference_normal") == texture, str(step.label) + ": source texture lost during variant switch")
        await _capture_pair(str(step.label), coast.water_material)
    report["failures"] = failures
    var handle := FileAccess.open(output_dir.path_join("recovered-water-report.json"), FileAccess.WRITE)
    if handle != null:
        handle.store_string(JSON.stringify(report, "  ") + "\n")
        handle.close()
    else:
        _check(false, "Could not write evidence report")
    print("YARDMAN_RECOVERED_WATER_RENDER_TEST %s method=%s paired_captures=%d failures=%d" % ["PASS" if failures == 0 else "FAIL", actual, report.captures.size(), failures])
    coast.queue_free()
    await process_frame
    quit(0 if failures == 0 else 1)
