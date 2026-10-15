extends SceneTree

# This test requires an actual display and renderer. It uses generated geometry
# with production shaders, so no recovered/private media or national data is
# required. The diagnostic reads the internal 3D resolution from shader output;
# checking the scaling property alone would miss a backend ignoring it.
const Manager = preload("res://scripts/render_quality_manager.gd")
const Registry = preload("res://scripts/render_material_registry.gd")
const CAPTURE_SIZE := Vector2i(960, 540)
const DIMENSION_SHADER := """
shader_type spatial;
render_mode unshaded, fog_disabled, cull_disabled;
void fragment() {
    int bit_index = clamp(int(floor(UV.x * 16.0)), 0, 15);
    int dimension = int(round(UV.y < 0.5 ? VIEWPORT_SIZE.x : VIEWPORT_SIZE.y));
    int bit_value = (dimension >> bit_index) & 1;
    ALBEDO = vec3(float(bit_value));
}
"""

var failures := 0
var output_dir := ""
var scene: Node3D
var diagnostic: SubViewport
var report: Dictionary = {}
var fixture_camera: Camera3D
var panel_centres: Array[Vector3] = []
# Optional real-render fault controls: missing_panel, flat_panel, black_panel.
# YARDMAN_RENDER_FIXTURE_CONTROL_PANEL selects one of the six panels (0..5).
# Every control must exit nonzero at both capture scales.
var fixture_control := ""
var fixture_control_panel := 4

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("RENDER_RUNTIME_CAPTURE_TEST: " + message)

func _add_box(parent: Node3D, position: Vector3, dimensions: Vector3, material: Material) -> MeshInstance3D:
    var instance := MeshInstance3D.new()
    var box := BoxMesh.new()
    box.size = dimensions
    instance.mesh = box
    instance.material_override = material
    instance.position = position
    parent.add_child(instance)
    return instance

func _make_scene() -> void:
    scene = Node3D.new()
    root.add_child(scene)
    var environment := WorldEnvironment.new()
    var settings := Environment.new()
    settings.background_mode = Environment.BG_COLOR
    settings.background_color = Color(0.035, 0.065, 0.105)
    settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    settings.ambient_light_color = Color(0.62, 0.70, 0.80)
    settings.ambient_light_energy = 0.55
    settings.tonemap_mode = Environment.TONE_MAPPER_LINEAR
    environment.environment = settings
    scene.add_child(environment)

    var sun := DirectionalLight3D.new()
    sun.rotation_degrees = Vector3(-48.0, -25.0, 0.0)
    sun.light_energy = 1.65
    sun.shadow_enabled = true
    scene.add_child(sun)
    var camera := Camera3D.new()
    camera.position = Vector3(8.0, 9.0, 11.5)
    camera.fov = 44.0
    scene.add_child(camera)
    camera.look_at(Vector3.ZERO)
    camera.current = true
    fixture_camera = camera

    var floor_material := StandardMaterial3D.new()
    # A neutral floor can masquerade as a missing grey road panel. Give the
    # supporting stage a diagnostic hue outside every material signature.
    floor_material.albedo_color = Color(0.22, 0.035, 0.16)
    floor_material.roughness = 0.94
    _add_box(scene, Vector3(0.0, -0.45, 0.0), Vector3(11.2, 0.3, 8.0), floor_material)
    var panels: Array = []
    var families := ["road", "terrain", "water"]
    for row in range(2):
        for column in range(3):
            var family: String = families[column]
            var safe: bool = row == 0
            var material := ShaderMaterial.new()
            material.shader = Registry.shader_for(family, "vulkan_mobile", "Quality", safe)
            if family == "road":
                material.set_shader_parameter("wetness", 0.65)
            var panel := _add_box(scene, Vector3((column - 1) * 3.5, -0.12, (row - 0.5) * 3.7), Vector3(3.0, 0.4, 3.0), material)
            # A single failed panel must fail even when the other five panels
            # and shaded hero keep the whole image bright and varied.
            if row * 3 + column == fixture_control_panel and not fixture_control.is_empty():
                if fixture_control == "missing_panel":
                    panel.visible = false
                else:
                    var broken := StandardMaterial3D.new()
                    broken.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
                    broken.albedo_color = Color.BLACK if fixture_control == "black_panel" else Color(0.4, 0.4, 0.4)
                    panel.material_override = broken
            panel_centres.append(Vector3((column - 1) * 3.5, 0.08, (row - 0.5) * 3.7))
            panels.append({"family": family, "variant": "safe" if safe else "high", "shader": material.shader.resource_path})
    var hero_material := StandardMaterial3D.new()
    hero_material.albedo_color = Color(0.85, 0.18, 0.025)
    hero_material.metallic = 0.5
    hero_material.roughness = 0.22
    var sphere := MeshInstance3D.new()
    var sphere_mesh := SphereMesh.new()
    sphere_mesh.radius = 0.7
    sphere_mesh.height = 1.4
    sphere.mesh = sphere_mesh
    sphere.material_override = hero_material
    sphere.position = Vector3(0.0, 0.65, 0.0)
    scene.add_child(sphere)
    report["visible_shader_panels"] = panels

func _make_diagnostic() -> void:
    diagnostic = SubViewport.new()
    diagnostic.size = CAPTURE_SIZE
    diagnostic.own_world_3d = true
    diagnostic.render_target_update_mode = SubViewport.UPDATE_ALWAYS
    root.add_child(diagnostic)
    var camera := Camera3D.new()
    camera.projection = Camera3D.PROJECTION_ORTHOGONAL
    camera.size = 2.0
    camera.position.z = 1.0
    diagnostic.add_child(camera)
    camera.current = true
    var quad := MeshInstance3D.new()
    var mesh := QuadMesh.new()
    mesh.size = Vector2(2.0 * float(CAPTURE_SIZE.x) / CAPTURE_SIZE.y, 2.0)
    quad.mesh = mesh
    var material := ShaderMaterial.new()
    var shader := Shader.new()
    shader.code = DIMENSION_SHADER
    material.shader = shader
    quad.material_override = material
    diagnostic.add_child(quad)

func _read_dimension(image: Image, y: int) -> int:
    var value := 0
    for bit_index in range(16):
        var x: int = int((float(bit_index) + 0.5) * image.get_width() / 16.0)
        if image.get_pixel(x, y).r > 0.5:
            value |= 1 << bit_index
    return value

func _measure_image(image: Image) -> Dictionary:
    var minimum := 1.0
    var maximum := 0.0
    var distinct: Dictionary = {}
    for y in range(0, image.get_height(), 4):
        for x in range(0, image.get_width(), 4):
            var color := image.get_pixel(x, y)
            var luma := color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722
            minimum = minf(minimum, luma)
            maximum = maxf(maximum, luma)
            distinct[Vector3i(int(color.r * 31.0), int(color.g * 31.0), int(color.b * 31.0))] = true
    return {"minimum_luma": minimum, "maximum_luma": maximum, "distinct_rgb_5bit": distinct.size()}

func _panel_color(image: Image, centre: Vector3) -> Color:
    var position := fixture_camera.unproject_position(centre)
    var red: Array[float] = []
    var green: Array[float] = []
    var blue: Array[float] = []
    # A small interior patch avoids a single resampling/animation-dependent
    # pixel becoming the oracle. Keep this away from panel borders and hero.
    for y in range(-2, 3):
        for x in range(-2, 3):
            var color := image.get_pixel(clampi(roundi(position.x) + x, 0, image.get_width() - 1), clampi(roundi(position.y) + y, 0, image.get_height() - 1))
            red.append(color.r)
            green.append(color.g)
            blue.append(color.b)
    red.sort()
    green.sort()
    blue.sort()
    return Color(red[12], green[12], blue[12])

func _panel_has_material_signature(color: Color, family: String) -> bool:
    # Broad fixture semantics, rather than exact backend colors: the road is
    # neutral grey, terrain is warm earth/grass, water is blue-green. These
    # margins accommodate GLES/Vulkan lighting and water phase differences.
    if family == "road":
        # The fixed blue ambient light gives the neutral asphalt a small cool
        # bias; an unshaded flat grey or default white material must not pass.
        return color.r > 0.12 and color.b < 0.80 and color.b - color.r > 0.025 and color.g - color.r > 0.01 and color.b - color.r < 0.18
    if family == "terrain":
        return color.r - color.b > 0.12 and color.g - color.b > 0.10 and color.g > 0.25
    return color.b - color.r > 0.10 and color.g - color.r > 0.07 and color.b - color.g > 0.025

func _measure_hero(image: Image) -> Dictionary:
    var centre := fixture_camera.unproject_position(Vector3(0.0, 0.65, 0.0))
    var edge := fixture_camera.unproject_position(Vector3(0.0, 0.65, 0.0) + fixture_camera.global_basis.x * 0.65)
    var radius := centre.distance_to(edge)
    var minimum := 1.0
    var maximum := 0.0
    var red_pixels := 0
    for y in range(roundi(centre.y - radius), roundi(centre.y + radius) + 1, 2):
        for x in range(roundi(centre.x - radius), roundi(centre.x + radius) + 1, 2):
            if Vector2(x, y).distance_to(centre) > radius:
                continue
            var color := image.get_pixel(clampi(x, 0, image.get_width() - 1), clampi(y, 0, image.get_height() - 1))
            # Exclude floor, panels and white specular highlights. Shaded red
            # body pixels must independently demonstrate curved-surface light.
            if color.r > color.g * 1.5 + 0.05 and color.r > color.b * 1.5 + 0.05:
                red_pixels += 1
                var luma := color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722
                minimum = minf(minimum, luma)
                maximum = maxf(maximum, luma)
    return {"red_pixels": red_pixels, "minimum_luma": minimum, "maximum_luma": maximum, "luma_range": maximum - minimum}

func _capture(scale: float) -> void:
    root.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
    root.scaling_3d_scale = scale
    diagnostic.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
    diagnostic.scaling_3d_scale = scale
    for frame in range(12):
        await process_frame
    await RenderingServer.frame_post_draw
    var image := root.get_texture().get_image()
    var dimensions_image := diagnostic.get_texture().get_image()
    _check(image != null and not image.is_empty(), "Scene did not produce an engine image")
    _check(dimensions_image != null and not dimensions_image.is_empty(), "Resolution diagnostic did not render")
    if image == null or image.is_empty() or dimensions_image == null or dimensions_image.is_empty():
        return
    var measured := Vector2i(_read_dimension(dimensions_image, CAPTURE_SIZE.y / 4), _read_dimension(dimensions_image, CAPTURE_SIZE.y * 3 / 4))
    var expected := Vector2i(int(CAPTURE_SIZE.x * scale), int(CAPTURE_SIZE.y * scale))
    _check(measured == expected, "Rendered internal dimensions %s do not match requested %s at scale %.2f" % [measured, expected, scale])
    _check(image.get_size() == CAPTURE_SIZE, "3D scaling resized the final UI/output canvas")
    var metrics := _measure_image(image)
    _check(float(metrics.maximum_luma) - float(metrics.minimum_luma) > 0.2, "Captured scene lacks measurable lighting contrast")
    # Whole-image quantized color counts remain diagnostic only: edge sampling,
    # water TIME and backend dithering change them without a material failure.
    # Check the actual six materials and curved hero instead.
    var panel_pixels: Array = []
    for index in range(panel_centres.size()):
        var color := _panel_color(image, panel_centres[index])
        panel_pixels.append([color.r, color.g, color.b])
        var family: String = report.visible_shader_panels[index].family
        _check(_panel_has_material_signature(color, family), "Production shader panel %d (%s) lost its material signature: %s" % [index, family, color])
    var hero_metrics := _measure_hero(image)
    _check(int(hero_metrics.red_pixels) >= 12, "Hero material is missing or lost its red identity")
    _check(float(hero_metrics.luma_range) > 0.06, "Hero curved surface lacks measurable shading")
    var name := "scale-%03d" % roundi(scale * 100.0)
    _check(image.save_png(output_dir.path_join(name + ".png")) == OK, "Could not save scene capture")
    _check(dimensions_image.save_png(output_dir.path_join(name + "-dimensions.png")) == OK, "Could not save diagnostic capture")
    report["captures"].append({
        "scale": scale, "internal_width": measured.x, "internal_height": measured.y,
        "output_width": image.get_width(), "output_height": image.get_height(),
        "image": name + ".png", "dimension_image": name + "-dimensions.png", "metrics": metrics, "panel_pixels": panel_pixels, "hero_metrics": hero_metrics,
    })

func _run() -> void:
    if DisplayServer.get_name() == "headless":
        _check(false, "A real display is required; headless success is not render evidence")
        quit(1)
        return
    # Production autoloads create startup/garage overlays even in a test scene.
    # Freeze them and hide their canvases so the image measures the 3D fixture.
    await process_frame
    paused = false
    for child in root.get_children():
        child.process_mode = Node.PROCESS_MODE_DISABLED
    for canvas in root.find_children("*", "CanvasLayer", true, false):
        canvas.visible = false
    output_dir = OS.get_environment("YARDMAN_RENDER_CAPTURE_DIR")
    if output_dir.is_empty():
        output_dir = ProjectSettings.globalize_path("user://render-runtime-captures")
    _check(DirAccess.make_dir_recursive_absolute(output_dir) == OK, "Could not create capture directory")
    root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
    root.content_scale_size = Vector2i.ZERO
    root.size = CAPTURE_SIZE
    var actual_method := RenderingServer.get_current_rendering_method()
    fixture_control = OS.get_environment("YARDMAN_RENDER_FIXTURE_CONTROL")
    var control_panel_text := OS.get_environment("YARDMAN_RENDER_FIXTURE_CONTROL_PANEL")
    if not control_panel_text.is_empty():
        fixture_control_panel = control_panel_text.to_int()
        _check(control_panel_text.is_valid_int() and fixture_control_panel >= 0 and fixture_control_panel < 6, "Invalid render fixture control panel")
    _check(fixture_control in ["", "missing_panel", "black_panel", "flat_panel"], "Unknown render fixture negative control")
    var expected_method := OS.get_environment("YARDMAN_EXPECT_RENDER_METHOD")
    _check(not expected_method.is_empty(), "Set YARDMAN_EXPECT_RENDER_METHOD to reject silent renderer fallback")
    _check(actual_method == expected_method, "Actual renderer %s differs from required %s" % [actual_method, expected_method])
    var expected_family := "vulkan_mobile" if actual_method == "mobile" else "gles"
    _check(Manager.renderer_family() == expected_family, "Manager used configured renderer instead of active backend")
    _check(Registry.renderer_family() == expected_family, "Material registry used configured renderer instead of active backend")
    for family in ["road", "terrain", "water"]:
        _check(Registry.variant_name(family, "", "Ultra") == "%s:%s" % [family, "safe" if expected_family == "gles" else "high"], "Wrong actual-backend shader selection for " + family)
    var manager = Manager.new()
    manager.configure("Ultra")
    manager.apply_viewport(root)
    var applied_policy_scale: float = root.scaling_3d_scale
    _check(is_equal_approx(applied_policy_scale, manager.current_scale), "Policy scale was not applied to the viewport")
    report = {
        "engine": Engine.get_version_info(), "method": actual_method, "renderer_family": expected_family,
        "adapter": RenderingServer.get_video_adapter_name(), "display": DisplayServer.get_name(),
        "policy_scale": applied_policy_scale, "captures": [],
        "fixture_control": fixture_control,
        "fixture_control_panel": fixture_control_panel if not fixture_control.is_empty() else -1,
        "scope": "Actual host render of generated fixture and production shaders; not Android device or national-world acceptance",
    }
    _make_scene()
    _make_diagnostic()
    await _capture(1.0)
    await _capture(0.7)
    report["failures"] = failures
    var handle := FileAccess.open(output_dir.path_join("render-runtime-report.json"), FileAccess.WRITE)
    if handle != null:
        handle.store_string(JSON.stringify(report, "  ") + "\n")
        handle.close()
    else:
        _check(false, "Could not save capture report")
    print("YARDMAN_RENDER_RUNTIME_CAPTURE_TEST %s method=%s scales=1.0,0.7 actual_images=%d failures=%d" % ["PASS" if failures == 0 else "FAIL", actual_method, report.captures.size(), failures])
    scene.queue_free()
    diagnostic.queue_free()
    await process_frame
    quit(0 if failures == 0 else 1)
