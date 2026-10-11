extends SceneTree

# Compare the production ground shader to the same recovered texture under
# identical real lighting. This catches extra color gain in shader translation.
const Visuals = preload("res://scripts/world_visuals.gd")
const References = preload("res://scripts/reference_assets.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("TERRAIN_REFERENCE_RENDER: " + message)

func _sample(image: Image, camera: Camera3D, center: Vector3) -> Vector3:
    var sum := Vector3.ZERO
    for y in range(25):
        for x in range(25):
            var world := center + Vector3((float(x) / 24.0 - 0.5) * 5.8, 0, (float(y) / 24.0 - 0.5) * 5.8)
            var pixel := camera.unproject_position(world)
            var color := image.get_pixel(clampi(roundi(pixel.x), 0, image.get_width() - 1), clampi(roundi(pixel.y), 0, image.get_height() - 1))
            sum += Vector3(color.r, color.g, color.b)
    return sum / 625.0

func _run() -> void:
    if DisplayServer.get_name() == "headless":
        push_error("terrain_reference_render_test requires an actual GL display")
        quit(1)
        return
    var texture := References.texture("ground_grass.png")
    if texture == null:
        _check(OS.get_environment("YARDMAN_REQUIRE_REFERENCE") != "1", "Required ground reference is missing")
        print("YARDMAN_TERRAIN_REFERENCE_RENDER %s private_pack=0 fallback=1" % ("PASS" if failures == 0 else "FAIL"))
        quit(failures)
        return
    var stage := Node3D.new()
    root.add_child(stage)
    var visuals := Visuals.new()
    var world := WorldEnvironment.new()
    var environment := Environment.new()
    var sun := DirectionalLight3D.new()
    stage.add_child(world)
    stage.add_child(sun)
    visuals.configure_environment(environment, sun)
    environment.fog_enabled = false
    sun.shadow_enabled = false
    world.environment = environment
    var production := visuals.terrain_material(Vector2.ZERO)
    # Identical wet/dry input isolates brightness translation from the regional
    # blend. Production noise, shading and texture mapping remain active.
    production.set_shader_parameter("reference_dry_grass", texture)
    var control := StandardMaterial3D.new()
    control.albedo_texture = texture
    control.roughness = 0.96
    control.metallic_specular = 0.14
    control.uv1_offset = Vector3(-0.5, -0.5, 0)
    for index in range(2):
        var instance := MeshInstance3D.new()
        var plane := PlaneMesh.new()
        plane.size = Vector2(8, 8)
        instance.mesh = plane
        instance.position.x = -6.0 if index == 0 else 6.0
        instance.material_override = production if index == 0 else control
        stage.add_child(instance)
    var camera := Camera3D.new()
    camera.projection = Camera3D.PROJECTION_ORTHOGONAL
    camera.size = 27.0
    camera.position = Vector3(0, 19, 8)
    stage.add_child(camera)
    camera.look_at(Vector3.ZERO)
    camera.current = true
    for frame in range(18):
        await process_frame
    await RenderingServer.frame_post_draw
    var image := root.get_texture().get_image()
    _check(image != null, "Actual renderer returned no image")
    if image != null:
        var measured := _sample(image, camera, Vector3(-6, 0, 0))
        var reference := _sample(image, camera, Vector3(6, 0, 0))
        var ratio := measured.length() / maxf(reference.length(), 0.0001)
        _check(reference.y > 0.15, "Control texture did not render")
        _check(ratio > 0.70 and ratio < 1.18, "Ground brightness diverged from the same source texture: %.4f" % ratio)
        print("YARDMAN_TERRAIN_REFERENCE_FRAME production_rgb=%s control_rgb=%s brightness_ratio=%.4f samples=625" % [measured, reference, ratio])
        var output := OS.get_environment("YARDMAN_RENDER_OUTPUT_DIR")
        if output.is_empty():
            output = "user://terrain-reference"
        DirAccess.make_dir_recursive_absolute(output)
        _check(image.save_png(output.path_join("terrain-reference-control.png")) == OK, "Could not save comparison")
    print("YARDMAN_TERRAIN_REFERENCE_RENDER %s compatibility=1 paired_source_control=1" % ("PASS" if failures == 0 else "FAIL"))
    stage.queue_free()
    await process_frame
    quit(failures)
