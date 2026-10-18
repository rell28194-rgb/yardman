extends SceneTree

# Actual GL regression for the visual-only Jamaica terrain elevation zoning.
# The fixture deliberately disables private reference textures so this remains
# deterministic in public CI while compiling both high and Android-safe shaders.
const Visuals = preload("res://scripts/world_visuals.gd")
const Registry = preload("res://scripts/render_material_registry.gd")
const SIZE := Vector2i(320, 240)
const LOWLAND_M := 120.0
const MONTANE_M := 1400.0
var failures := 0
var output_dir := ""

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("TERRAIN_MONTANE_RENDER: " + message)

func _terrain_mesh(elevation: float) -> ArrayMesh:
    var vertices := PackedVector3Array([
        Vector3(-5.0, elevation, -5.0), Vector3(5.0, elevation, -5.0),
        Vector3(-5.0, elevation, 5.0), Vector3(5.0, elevation, 5.0),
    ])
    var normals := PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
    var indices := PackedInt32Array([0, 1, 2, 1, 3, 2])
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = normals
    arrays[Mesh.ARRAY_INDEX] = indices
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    return mesh

func _fallback_material(shader: Shader) -> ShaderMaterial:
    var visuals := Visuals.new()
    var source := visuals.terrain_material(Vector2.ZERO)
    var material := ShaderMaterial.new()
    material.shader = shader
    material.set_shader_parameter("surface_noise", source.get_shader_parameter("surface_noise"))
    material.set_shader_parameter("tile_origin", Vector2.ZERO)
    material.set_shader_parameter("overview", false)
    material.set_shader_parameter("has_reference_ground", false)
    material.set_shader_parameter("has_reference_rock", false)
    material.set_shader_parameter("has_reference_grass_normal", false)
    return material

func _average_center(image: Image) -> Vector3:
    var total := Vector3.ZERO
    var count := 0
    for y in range(50, SIZE.y - 50):
        for x in range(70, SIZE.x - 70):
            var color := image.get_pixel(x, y)
            total += Vector3(color.r, color.g, color.b)
            count += 1
    return total / maxf(float(count), 1.0)

func _render(material: ShaderMaterial, elevation: float, label: String) -> Dictionary:
    var viewport := SubViewport.new()
    viewport.size = SIZE
    viewport.own_world_3d = true
    viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
    root.add_child(viewport)

    var environment_node := WorldEnvironment.new()
    var environment := Environment.new()
    environment.background_mode = Environment.BG_COLOR
    environment.background_color = Color(0.08, 0.11, 0.14)
    environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    environment.ambient_light_color = Color(0.72, 0.78, 0.82)
    environment.ambient_light_energy = 0.32
    environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
    environment_node.environment = environment
    viewport.add_child(environment_node)

    var sun := DirectionalLight3D.new()
    sun.rotation_degrees = Vector3(-42.0, -28.0, 0.0)
    sun.light_color = Color(1.0, 0.96, 0.88)
    sun.light_energy = 1.15
    sun.shadow_enabled = false
    viewport.add_child(sun)

    var ground := MeshInstance3D.new()
    ground.mesh = _terrain_mesh(elevation)
    ground.material_override = material
    viewport.add_child(ground)

    var camera := Camera3D.new()
    camera.projection = Camera3D.PROJECTION_ORTHOGONAL
    camera.size = 11.5
    camera.position = Vector3(0.0, elevation + 16.0, 6.0)
    camera.near = 0.05
    camera.far = 60.0
    viewport.add_child(camera)
    camera.look_at(Vector3(0.0, elevation, 0.0))
    camera.current = true

    for frame in range(10):
        await process_frame
    await RenderingServer.frame_post_draw
    var image := viewport.get_texture().get_image()
    _check(image != null, label + ": renderer returned no image")
    if image == null:
        viewport.queue_free()
        await process_frame
        return {"rgb": Vector3.ZERO}
    var rgb := _average_center(image)
    _check(rgb.x > 0.03 and rgb.y > 0.03 and rgb.z > 0.02, label + ": terrain rendered too dark: " + str(rgb))
    _check(maxf(rgb.x, maxf(rgb.y, rgb.z)) < 0.92, label + ": terrain clipped too bright: " + str(rgb))
    _check(image.save_png(output_dir.path_join(label + ".png")) == OK, label + ": could not save evidence image")
    viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
    viewport.queue_free()
    await process_frame
    return {"rgb": rgb}

func _green_share(rgb: Vector3) -> float:
    return rgb.y / maxf(rgb.x + rgb.y + rgb.z, 0.0001)

func _distance(a: Vector3, b: Vector3) -> float:
    return (a - b).length()

func _run() -> void:
    if DisplayServer.get_name() == "headless":
        _check(false, "Actual GL display required")
        quit(1)
        return
    output_dir = OS.get_environment("YARDMAN_TERRAIN_MONTANE_CAPTURE_DIR")
    if output_dir.is_empty():
        output_dir = "user://terrain-montane"
    _check(DirAccess.make_dir_recursive_absolute(output_dir) == OK, "Could not create capture directory")

    var high := _fallback_material(Registry.TERRAIN_HIGH)
    var safe := _fallback_material(Registry.TERRAIN_SAFE)
    var high_low: Dictionary = await _render(high, LOWLAND_M, "high-lowland")
    var high_montane: Dictionary = await _render(high, MONTANE_M, "high-montane")
    var safe_low: Dictionary = await _render(safe, LOWLAND_M, "safe-lowland")
    var safe_montane: Dictionary = await _render(safe, MONTANE_M, "safe-montane")

    var high_low_rgb: Vector3 = high_low.rgb
    var high_montane_rgb: Vector3 = high_montane.rgb
    var safe_low_rgb: Vector3 = safe_low.rgb
    var safe_montane_rgb: Vector3 = safe_montane.rgb
    _check(_distance(high_low_rgb, high_montane_rgb) > 0.015,
        "High-quality shader lost visible elevation zoning")
    _check(_distance(safe_low_rgb, safe_montane_rgb) > 0.012,
        "Android-safe shader lost visible elevation zoning")
    _check(_green_share(high_montane_rgb) > _green_share(high_low_rgb) + 0.003,
        "High-quality montane ground is not perceptibly cooler/greener")
    _check(_green_share(safe_montane_rgb) > _green_share(safe_low_rgb) + 0.003,
        "Android-safe montane ground is not perceptibly cooler/greener")

    print("YARDMAN_TERRAIN_MONTANE_FRAME high_low=%s high_montane=%s safe_low=%s safe_montane=%s" %
        [high_low_rgb, high_montane_rgb, safe_low_rgb, safe_montane_rgb])
    print("YARDMAN_TERRAIN_MONTANE_RENDER %s high_delta=%.4f safe_delta=%.4f" %
        ["PASS" if failures == 0 else "FAIL", _distance(high_low_rgb, high_montane_rgb),
        _distance(safe_low_rgb, safe_montane_rgb)])
    quit(0 if failures == 0 else 1)
