extends SceneTree

const Registry = preload("res://scripts/render_material_registry.gd")
const QualityManager = preload("res://scripts/render_quality_manager.gd")
const COMMON_SHADER_PATHS := [
    "res://shaders/building_surface.gdshader",
    "res://shaders/foliage.gdshader",
    "res://shaders/tree_bark.gdshader",
    "res://shaders/beach.gdshader",
]
const VIEWPORT_SIZE := Vector2i(640, 360)
const SETTLE_FRAMES := 12

var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("RDX_RENDERER_MATRIX_TEST: " + message)

func _run() -> void:
    var expected_method := OS.get_environment("YARDMAN_EXPECT_METHOD")
    var expected_driver := OS.get_environment("YARDMAN_EXPECT_DRIVER")
    var expected_rd_text := OS.get_environment("YARDMAN_EXPECT_RD")
    var expected_family := OS.get_environment("YARDMAN_EXPECT_FAMILY")
    var label := OS.get_environment("YARDMAN_RENDERER_LABEL")
    if label.is_empty():
        label = "unknown"

    _check(not expected_method.is_empty(), "YARDMAN_EXPECT_METHOD is required")
    _check(not expected_driver.is_empty(), "YARDMAN_EXPECT_DRIVER is required")
    _check(expected_rd_text == "0" or expected_rd_text == "1", "YARDMAN_EXPECT_RD must be 0 or 1")
    _check(expected_family == "gles" or expected_family == "vulkan_mobile", "YARDMAN_EXPECT_FAMILY must be gles or vulkan_mobile")

    var method := RenderingServer.get_current_rendering_method()
    var driver := RenderingServer.get_current_rendering_driver_name()
    var rendering_device := RenderingServer.get_rendering_device()
    var rd_present := rendering_device != null
    var expected_rd := expected_rd_text == "1"
    var quality_family := QualityManager.renderer_family()
    var registry_family := Registry.renderer_family()

    _check(method == expected_method, "rendering method mismatch: got %s expected %s" % [method, expected_method])
    _check(driver == expected_driver or driver.begins_with(expected_driver), "rendering driver mismatch: got %s expected prefix %s" % [driver, expected_driver])
    _check(rd_present == expected_rd, "RenderingDevice capability mismatch: got %s expected %s" % [str(rd_present), str(expected_rd)])
    _check(quality_family == expected_family, "quality renderer family mismatch: got %s expected %s" % [quality_family, expected_family])
    _check(registry_family == expected_family, "material renderer family mismatch: got %s expected %s" % [registry_family, expected_family])

    var policy := QualityManager.policy_for("Balanced", quality_family)
    _validate_quality_policy(expected_family, policy)
    var selected_shaders := _load_selected_production_shaders(expected_family)
    var render_metrics := await _render_shader_probe(selected_shaders)

    var status := "PASS" if failures == 0 else "FAIL"
    print("YARDMAN_RDX_RENDERER_MATRIX label=%s method=%s driver=%s family=%s rd=%d shaders=%d luma=%.6f lit_samples=%d road=%s water=%s terrain=%s result=%s" % [
        label, method, driver, quality_family, int(rd_present), selected_shaders.size(),
        float(render_metrics.get("luma", 0.0)), int(render_metrics.get("lit_samples", 0)),
        Registry.variant_name("road"), Registry.variant_name("water"), Registry.variant_name("terrain"), status])
    quit(0 if failures == 0 else 1)

func _validate_quality_policy(expected_family: String, policy: Dictionary) -> void:
    if expected_family == "gles":
        _check(str(policy.road_variant) == "safe", "Compatibility escaped safe road material policy")
        _check(str(policy.water_variant) == "opaque", "Compatibility escaped opaque water policy")
        _check(str(policy.terrain_variant) == "2layer", "Compatibility escaped two-layer terrain policy")
        _check(not bool(policy.screen_effects), "Compatibility retained expensive screen effects")
        _check(float(policy.resolution_max) <= 0.82, "Compatibility escaped GLES resolution cap")
    else:
        _check(str(policy.road_variant) == "high", "Mobile/Vulkan Balanced lost high road material policy")
        _check(str(policy.water_variant) == "dual_normal", "Mobile/Vulkan Balanced lost dual-normal water policy")
        _check(str(policy.terrain_variant) == "2layer", "Mobile/Vulkan Balanced terrain policy changed")
        _check(float(policy.resolution_max) >= 0.95, "Mobile/Vulkan Balanced lost intended resolution ceiling")

func _expected_surface_path(surface: String, expected_family: String) -> String:
    var safe := expected_family == "gles"
    match surface:
        "road":
            return "res://shaders/road_surface_gles.gdshader" if safe else "res://shaders/road_surface.gdshader"
        "water":
            return "res://shaders/water_gles.gdshader" if safe else "res://shaders/water.gdshader"
        "terrain":
            return "res://shaders/terrain_surface_gles.gdshader" if safe else "res://shaders/terrain_surface.gdshader"
        _:
            return ""

func _load_selected_production_shaders(expected_family: String) -> Array[Shader]:
    var result: Array[Shader] = []
    for surface in ["road", "water", "terrain"]:
        var shader: Shader = Registry.shader_for(surface)
        var expected_path := _expected_surface_path(surface, expected_family)
        _check(shader != null, "%s production material did not resolve a shader" % surface)
        if shader != null:
            _check(shader.resource_path == expected_path, "%s runtime shader mismatch: got %s expected %s" % [surface, shader.resource_path, expected_path])
            _check(Registry.variant_name(surface) == "%s:%s" % [surface, "safe" if expected_family == "gles" else "high"], "%s runtime variant name disagrees with active renderer" % surface)
            result.append(shader)
        var performance_shader: Shader = Registry.shader_for(surface, "", "Performance")
        _check(performance_shader != null and performance_shader.resource_path == _expected_surface_path(surface, "gles"), "%s Performance tier escaped safe shader" % surface)
        var forced_safe: Shader = Registry.shader_for(surface, "", "Balanced", true)
        _check(forced_safe != null and forced_safe.resource_path == _expected_surface_path(surface, "gles"), "%s forced-safe fallback did not resolve safe shader" % surface)

    for path in COMMON_SHADER_PATHS:
        _check(ResourceLoader.exists(path), "common production shader missing: " + path)
        if not ResourceLoader.exists(path):
            continue
        var shader := load(path) as Shader
        _check(shader != null, "common production shader failed to load: " + path)
        if shader != null:
            result.append(shader)
    _check(result.size() == 7, "representative runtime shader set is incomplete")
    return result

func _render_shader_probe(shaders: Array[Shader]) -> Dictionary:
    var viewport := SubViewport.new()
    viewport.name = "RendererMatrixViewport"
    viewport.size = VIEWPORT_SIZE
    viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
    viewport.own_world_3d = true
    root.add_child(viewport)

    var environment := Environment.new()
    environment.background_mode = Environment.BG_COLOR
    environment.background_color = Color(0.03, 0.04, 0.06)
    environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    environment.ambient_light_color = Color(0.45, 0.48, 0.52)
    environment.ambient_light_energy = 1.0
    var world_environment := WorldEnvironment.new()
    world_environment.environment = environment
    viewport.add_child(world_environment)

    var camera := Camera3D.new()
    camera.position = Vector3(0.0, 1.8, 11.0)
    viewport.add_child(camera)
    camera.look_at(Vector3(0.0, 0.5, 0.0), Vector3.UP)
    camera.current = true

    var sun := DirectionalLight3D.new()
    sun.rotation_degrees = Vector3(-48.0, -32.0, 0.0)
    sun.light_energy = 1.8
    viewport.add_child(sun)

    var control_mesh := BoxMesh.new()
    control_mesh.size = Vector3(1.2, 1.2, 1.2)
    var control_material := StandardMaterial3D.new()
    control_material.albedo_color = Color(0.85, 0.35, 0.12)
    control_material.roughness = 0.65
    var control := MeshInstance3D.new()
    control.mesh = control_mesh
    control.material_override = control_material
    control.position = Vector3(-4.5, 0.5, 0.0)
    viewport.add_child(control)

    for index in range(shaders.size()):
        var material := ShaderMaterial.new()
        material.shader = shaders[index]
        var mesh := BoxMesh.new()
        mesh.size = Vector3(0.85, 0.85, 0.85)
        var instance := MeshInstance3D.new()
        instance.mesh = mesh
        instance.material_override = material
        var column: int = index % 4
        var row: int = index / 4
        instance.position = Vector3(-2.6 + float(column) * 1.7, 0.45 + float(row) * 1.45, 0.0)
        viewport.add_child(instance)

    for _frame in range(SETTLE_FRAMES):
        await process_frame
    await RenderingServer.frame_post_draw

    var image := viewport.get_texture().get_image()
    _check(image != null and not image.is_empty(), "renderer probe produced no image")
    var luma_sum := 0.0
    var samples := 0
    var lit_samples := 0
    if image != null and not image.is_empty():
        for y in range(8, image.get_height(), 16):
            for x in range(8, image.get_width(), 16):
                var pixel := image.get_pixel(x, y)
                var luma := pixel.r * 0.2126 + pixel.g * 0.7152 + pixel.b * 0.0722
                luma_sum += luma
                samples += 1
                if luma > 0.075:
                    lit_samples += 1
    var average_luma := luma_sum / float(maxi(samples, 1))
    _check(samples > 0, "renderer probe sampled no pixels")
    _check(average_luma > 0.01, "renderer probe frame is effectively black")
    _check(lit_samples >= 4, "renderer probe has too few lit 3D samples")

    viewport.queue_free()
    await process_frame
    return {"luma": average_luma, "lit_samples": lit_samples}
