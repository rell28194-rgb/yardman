extends SceneTree

const Coastline = preload("res://scripts/coastline.gd")
var failures := 0
var output_dir := ""

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("WATER_SHORE_RENDER_TEST: " + message)

func _payload() -> Dictionary:
    # X is also the registered horizontal shore distance in this deterministic
    # visual fixture: zero at the mapped coast and forty metres offshore.
    return {
        "water": PackedVector3Array([
            Vector3(0, 0, 0), Vector3(40, 0, 0), Vector3(0, 0, 40),
            Vector3(40, 0, 0), Vector3(40, 0, 40), Vector3(0, 0, 40),
        ]),
        "shore_distance": PackedFloat32Array([0, 40, 0, 40, 40, 0]),
    }

func _freeze_variant(coast, renderer: String, quality: String) -> void:
    coast.apply_render_policy({"quality": quality}, renderer)
    var source: Shader = coast.water_material.shader
    _check(source != null, "Missing %s water shader" % renderer)
    if source == null:
        return
    var frozen := Shader.new()
    frozen.code = source.code.replace("TIME", "0.0")
    coast.water_material.shader = frozen
    for flag in ["has_reference_surface", "has_reference_foam", "has_reference_caustics", "has_reference_normal"]:
        coast.water_material.set_shader_parameter(flag, false)
    _check(frozen.code.find("shoreline_wash") >= 0, "%s shader lost shoreline wash stage" % renderer)

func _capture(name: String) -> Image:
    for frame in range(12):
        await process_frame
    await RenderingServer.frame_post_draw
    var picture := root.get_texture().get_image()
    if picture == null or picture.is_empty():
        _check(false, "No actual GL frame for " + name)
        return null
    if not output_dir.is_empty():
        _check(picture.save_png(output_dir.path_join(name + ".png")) == OK, "Could not save " + name)
    return picture

func _region_stats(picture: Image, camera: Camera3D, x0: float, x1: float, z0: float, z1: float) -> Dictionary:
    var screens: Array[Vector2] = [
        camera.unproject_position(Vector3(x0, 0, z0)),
        camera.unproject_position(Vector3(x1, 0, z0)),
        camera.unproject_position(Vector3(x0, 0, z1)),
        camera.unproject_position(Vector3(x1, 0, z1)),
    ]
    var min_x := picture.get_width() - 1
    var max_x := 0
    var min_y := picture.get_height() - 1
    var max_y := 0
    for point: Vector2 in screens:
        min_x = mini(min_x, clampi(int(floor(point.x)), 0, picture.get_width() - 1))
        max_x = maxi(max_x, clampi(int(ceil(point.x)), 0, picture.get_width() - 1))
        min_y = mini(min_y, clampi(int(floor(point.y)), 0, picture.get_height() - 1))
        max_y = maxi(max_y, clampi(int(ceil(point.y)), 0, picture.get_height() - 1))
    var total := 0.0
    var peak := 0.0
    var rgb := Vector3.ZERO
    var count := 0
    for y in range(min_y, max_y + 1):
        for x in range(min_x, max_x + 1):
            var pixel := picture.get_pixel(x, y)
            var luminance := pixel.r * 0.2126 + pixel.g * 0.7152 + pixel.b * 0.0722
            total += luminance
            peak = maxf(peak, luminance)
            rgb += Vector3(pixel.r, pixel.g, pixel.b)
            count += 1
    return {
        "avg": total / float(maxi(count, 1)),
        "peak": peak,
        "rgb": rgb / float(maxi(count, 1)),
        "pixels": count,
    }

func _grade_variant(label: String, picture: Image, camera: Camera3D) -> Dictionary:
    # Exclude the exact contact line and the outer mesh edge; compare a mapped
    # 1.5-7 m shoreline band with genuinely offshore samples.
    var wash := _region_stats(picture, camera, 1.5, 7.0, 4.0, 36.0)
    var deep := _region_stats(picture, camera, 24.0, 38.0, 4.0, 36.0)
    var wash_rgb: Vector3 = wash.rgb
    var deep_rgb: Vector3 = deep.rgb
    var delta := wash_rgb.distance_to(deep_rgb)
    _check(int(wash.pixels) > 100 and int(deep.pixels) > 100, label + " sample regions too small")
    _check(float(wash.avg) > float(deep.avg) + 0.015, label + " mapped shoreline no longer separates from offshore water")
    _check(delta > 0.045, label + " shoreline/offshore colour response collapsed")
    _check(float(wash.peak) > float(wash.avg) + 0.010, label + " shoreline wash became a flat colour strip")
    # A dark/grey UI overlay can accidentally satisfy luminance deltas. Both
    # sampled regions must retain the blue-green chroma of the actual water.
    _check(wash_rgb.z > wash_rgb.x * 1.25 and deep_rgb.z > deep_rgb.x * 1.25,
        label + " capture does not contain the expected water chroma")
    return {"wash": wash, "deep": deep, "delta": delta}

func _run() -> void:
    if DisplayServer.get_name() == "headless":
        _check(false, "Actual GL display required")
        quit(1)
        return
    root.size = Vector2i(640, 480)
    var startup_menu := root.get_node_or_null("StartupMenu")
    if startup_menu != null:
        if startup_menu.has_method("_set_open"):
            startup_menu.call("_set_open", false)
        if startup_menu is CanvasItem:
            startup_menu.visible = false
    output_dir = OS.get_environment("YARDMAN_WATER_SHORE_CAPTURE_DIR")
    if not output_dir.is_empty():
        DirAccess.make_dir_recursive_absolute(output_dir)

    var world := Node3D.new()
    root.add_child(world)
    var world_environment := WorldEnvironment.new()
    world_environment.environment = Environment.new()
    world_environment.environment.background_mode = Environment.BG_COLOR
    world_environment.environment.background_color = Color(0.07, 0.10, 0.13)
    world_environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    world_environment.environment.ambient_light_color = Color(0.76, 0.82, 0.89)
    world_environment.environment.ambient_light_energy = 0.82
    world.add_child(world_environment)
    var sun := DirectionalLight3D.new()
    sun.rotation_degrees = Vector3(-48, 135, 0)
    sun.light_energy = 1.15
    world.add_child(sun)

    var coast := Coastline.new()
    world.add_child(coast)
    coast.append_water(_payload(), world, 0.0, 0.0)

    var camera := Camera3D.new()
    world.add_child(camera)
    camera.projection = Camera3D.PROJECTION_ORTHOGONAL
    camera.size = 48.0
    camera.position = Vector3(20, 50, 20)
    camera.rotation_degrees = Vector3(-90, 0, 0)
    camera.current = true

    _freeze_variant(coast, "vulkan_mobile", "Quality")
    var high_image := await _capture("shore-water-high")
    if high_image == null:
        quit(1)
        return
    var high := _grade_variant("high", high_image, camera)

    _freeze_variant(coast, "gles", "Performance")
    var safe_image := await _capture("shore-water-safe")
    if safe_image == null:
        quit(1)
        return
    var safe := _grade_variant("safe", safe_image, camera)

    # Safe rendering can simplify the water, but it must retain the same
    # geographic visual language rather than becoming a different coastline.
    var high_delta := float(high.delta)
    var safe_delta := float(safe.delta)
    _check(safe_delta >= high_delta * 0.55, "Safe shoreline response degraded too far from high quality")

    if failures == 0:
        print("YARDMAN_WATER_SHORE_RENDER PASS high_delta=%.4f safe_delta=%.4f high_wash=%.4f high_deep=%.4f safe_wash=%.4f safe_deep=%.4f renderer=%s" % [
            high_delta, safe_delta,
            float(high.wash.avg), float(high.deep.avg),
            float(safe.wash.avg), float(safe.deep.avg),
            RenderingServer.get_video_adapter_name(),
        ])
    world.queue_free()
    await process_frame
    quit(0 if failures == 0 else 1)
