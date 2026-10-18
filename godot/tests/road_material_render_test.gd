extends SceneTree

const Registry = preload("res://scripts/render_material_registry.gd")
const SIZE := Vector2i(720, 480)
var failures := 0
var output_dir := ""

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("ROAD_MATERIAL_RENDER_TEST: " + message)

func _hide_project_overlays() -> void:
    var startup := root.get_node_or_null("StartupMenu")
    if startup != null and startup.has_method("_set_open"):
        startup.call("_set_open", false)
    for path in [
        "/root/StartupMenu/StartupMenuScreen",
        "/root/ParishMapRuntime/ParishMapButton",
        "/root/ParishMapRuntime/ParishMapOverlay",
        "/root/VehicleGarage/GarageUI",
    ]:
        var overlay := root.get_node_or_null(path)
        if overlay is CanvasItem:
            overlay.visible = false

func _road_mesh() -> ArrayMesh:
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
        Vector3(-6.0, 0.0, 10.0), Vector3(6.0, 0.0, 10.0),
        Vector3(-6.0, 0.0, -55.0), Vector3(6.0, 0.0, -55.0),
    ])
    arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
    # Production road UVs are metre-like: X is longitudinal and Y is lateral.
    arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
        Vector2(0.0, -6.0), Vector2(0.0, 6.0),
        Vector2(65.0, -6.0), Vector2(65.0, 6.0),
    ])
    arrays[Mesh.ARRAY_TEX_UV2] = PackedVector2Array([
        Vector2(30.0, 30.0), Vector2(30.0, 30.0),
        Vector2(30.0, 30.0), Vector2(30.0, 30.0),
    ])
    var road_color := Color(12.0 / 64.0, 1.0, 2.0 / 8.0, 1.0)
    arrays[Mesh.ARRAY_COLOR] = PackedColorArray([road_color, road_color, road_color, road_color])
    arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 2, 1, 1, 2, 3])
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    return mesh

func _fixture_texture(detail: bool) -> ImageTexture:
    var image := Image.create(64, 64, false, Image.FORMAT_RGB8)
    for y in range(64):
        for x in range(64):
            var cell := float((x * 17 + y * 29 + (x * y) % 23) % 97) / 96.0
            if detail:
                var value := 0.24 + cell * 0.58
                image.set_pixel(x, y, Color(value, value * 0.98, value * 0.93))
            else:
                var value := 0.075 + cell * 0.035
                image.set_pixel(x, y, Color(value, value * 1.03, value * 1.07))
    image.generate_mipmaps()
    return ImageTexture.create_from_image(image)

func _capture(name: String) -> Image:
    for frame in range(10):
        _hide_project_overlays()
        await process_frame
    _hide_project_overlays()
    await RenderingServer.frame_post_draw
    var image := root.get_texture().get_image()
    _check(image != null and not image.is_empty(), "No GL frame for " + name)
    if image != null and not image.is_empty() and not output_dir.is_empty():
        _check(image.save_png(output_dir.path_join(name + ".png")) == OK, "Could not save " + name)
    return image

func _road_samples(image: Image, camera: Camera3D) -> Dictionary:
    var values: Array[float] = []
    var rgb := Vector3.ZERO
    for zi in range(18):
        var z := lerpf(-42.0, -8.0, float(zi) / 17.0)
        for xi in range(9):
            var x := lerpf(-4.2, 4.2, float(xi) / 8.0)
            var point := camera.unproject_position(Vector3(x, 0.02, z))
            var px := clampi(roundi(point.x), 0, image.get_width() - 1)
            var py := clampi(roundi(point.y), 0, image.get_height() - 1)
            var color := image.get_pixel(px, py)
            var luma := color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722
            values.append(luma)
            rgb += Vector3(color.r, color.g, color.b)
    var mean := 0.0
    var minimum := INF
    var maximum := -INF
    for value: float in values:
        mean += value
        minimum = minf(minimum, value)
        maximum = maxf(maximum, value)
    mean /= float(maxi(values.size(), 1))
    var variance := 0.0
    for value: float in values:
        variance += pow(value - mean, 2.0)
    variance /= float(maxi(values.size(), 1))
    return {
        "mean": mean,
        "variance": variance,
        "range": maximum - minimum,
        "rgb": rgb / float(maxi(values.size(), 1)),
        "samples": values.size(),
    }

func _run() -> void:
    if DisplayServer.get_name() == "headless":
        _check(false, "Actual GL display required")
        quit(1)
        return
    root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
    root.content_scale_size = Vector2i.ZERO
    root.size = SIZE
    root.scaling_3d_scale = 1.0
    _hide_project_overlays()
    output_dir = OS.get_environment("YARDMAN_ROAD_MATERIAL_CAPTURE_DIR")
    if not output_dir.is_empty():
        DirAccess.make_dir_recursive_absolute(output_dir)

    var world := Node3D.new()
    root.add_child(world)
    var world_environment := WorldEnvironment.new()
    world_environment.environment = Environment.new()
    world_environment.environment.background_mode = Environment.BG_COLOR
    world_environment.environment.background_color = Color(0.10, 0.15, 0.19)
    world_environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    world_environment.environment.ambient_light_color = Color(0.48, 0.55, 0.62)
    world_environment.environment.ambient_light_energy = 0.44
    world.add_child(world_environment)

    var sun := DirectionalLight3D.new()
    sun.rotation_degrees = Vector3(-38.0, -35.0, 0.0)
    sun.light_energy = 1.55
    sun.light_color = Color(1.0, 0.94, 0.82)
    world.add_child(sun)

    var road := MeshInstance3D.new()
    road.mesh = _road_mesh()
    var material := ShaderMaterial.new()
    material.shader = Registry.shader_for("road", "vulkan_mobile", "Ultra", false)
    material.set_shader_parameter("reference_albedo", _fixture_texture(false))
    material.set_shader_parameter("reference_detail", _fixture_texture(true))
    material.set_shader_parameter("has_reference_albedo", true)
    material.set_shader_parameter("has_reference_detail", true)
    material.set_shader_parameter("visibility_distance", 500.0)
    road.material_override = material
    world.add_child(road)

    var camera := Camera3D.new()
    camera.position = Vector3(0.0, 4.8, 12.0)
    camera.fov = 58.0
    world.add_child(camera)
    camera.look_at(Vector3(0.0, 0.0, -18.0))
    camera.current = true

    var code := material.shader.code
    _check(code.find("micro_roughness") >= 0, "High asphalt lost micro-roughness stage")
    _check(code.count("texture(reference_detail") == 1, "Micro-roughness added extra reference-detail texture fetches")

    material.set_shader_parameter("wetness", 0.0)
    material.set_shader_parameter("standing_water", 0.0)
    var dry_image := await _capture("road-dry-high")
    var dry := _road_samples(dry_image, camera) if dry_image != null else {}

    material.set_shader_parameter("wetness", 0.82)
    material.set_shader_parameter("standing_water", 0.55)
    var wet_image := await _capture("road-wet-high")
    var wet := _road_samples(wet_image, camera) if wet_image != null else {}

    if not dry.is_empty() and not wet.is_empty():
        _check(int(dry.samples) >= 150, "Road sample footprint collapsed")
        _check(float(dry.range) > 0.018, "Dry asphalt became visually uniform")
        _check(float(dry.variance) > 0.00001, "Dry aggregate response has no measurable variation")
        _check(float(wet.mean) < float(dry.mean) - 0.004, "Wet asphalt no longer darkens against the dry surface")
        var dry_rgb: Vector3 = dry.rgb
        _check(dry_rgb.z >= dry_rgb.x * 0.82, "Asphalt fixture rendered with implausible channel collapse")

    if failures == 0:
        print("YARDMAN_ROAD_MATERIAL_RENDER PASS dry_mean=%.4f dry_range=%.4f dry_variance=%.6f wet_mean=%.4f renderer=%s" % [
            float(dry.mean), float(dry.range), float(dry.variance), float(wet.mean), RenderingServer.get_video_adapter_name()
        ])
    world.queue_free()
    await process_frame
    quit(0 if failures == 0 else 1)
