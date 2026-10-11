extends SceneTree

# Real Compatibility rendering gate for optional, owner-supplied foliage.
# Frames also retain the reference sedan as a metre-scale lighting comparison.
const Visuals = preload("res://scripts/world_visuals.gd")
const CarModel = preload("res://scripts/vehicle_model.gd")
var failures := 0
var stage: Node3D
var camera: Camera3D
var output: String
var plants: Dictionary = {}
var sedan: Node3D

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("REFERENCE_FOLIAGE_RENDER: " + message)

func _capture(name: String, position: Vector3, target: Vector3, check_green: bool = false, isolated_asset: String = "") -> void:
    # A neighboring tree must not hide a missing or discolored palm. These
    # close-up frames contain only their named plant, neutral ground and sky.
    for filename: String in plants:
        (plants[filename] as MultiMeshInstance3D).visible = isolated_asset.is_empty() or filename == isolated_asset
    if sedan != null:
        sedan.visible = isolated_asset.is_empty()
    if check_green:
        _check(not isolated_asset.is_empty() and plants.has(isolated_asset), name + ": green check did not isolate its target plant")
    camera.position = position
    camera.look_at(target)
    for frame in range(8):
        await process_frame
    await RenderingServer.frame_post_draw
    var image := get_root().get_texture().get_image()
    _check(image != null, name + ": renderer returned no frame")
    if image == null:
        return
    if check_green:
        var green_pixels := 0
        for y in range(60, image.get_height() - 60, 2):
            for x in range(60, image.get_width() - 60, 2):
                var pixel := image.get_pixel(x, y)
                if pixel.g > maxf(pixel.r, pixel.b) * 1.12 and pixel.g > 0.15:
                    green_pixels += 1
        _check(green_pixels > 250, name + ": actual leaf cards rendered grey or disappeared")
        print("YARDMAN_REFERENCE_FOLIAGE_FRAME name=%s asset=%s isolated=1 green_samples=%d" % [name, isolated_asset, green_pixels])
    var path := output.path_join(name + ".png")
    _check(image.save_png(path) == OK, "Could not save " + path)

func _run() -> void:
    if DisplayServer.get_name() == "headless":
        push_error("reference_foliage_render_test requires an actual GL display")
        quit(1)
        return
    var required := OS.get_environment("YARDMAN_REQUIRE_REFERENCE") == "1"
    output = OS.get_environment("YARDMAN_RENDER_OUTPUT_DIR")
    if output.is_empty():
        output = "user://reference-batch"
    DirAccess.make_dir_recursive_absolute(output)
    var visuals := Visuals.new()
    var palm_mesh: ArrayMesh = visuals._reference_plant_mesh("road_palm_short.glb", 8.2)
    if palm_mesh == null:
        _check(not required, "Required reference foliage failed import")
        print("YARDMAN_REFERENCE_FOLIAGE_RENDER %s private_pack=0 fallback=1" % ("PASS" if failures == 0 else "FAIL"))
        quit(failures)
        return
    stage = Node3D.new()
    root.add_child(stage)
    var world := WorldEnvironment.new()
    var environment := Environment.new()
    environment.background_mode = Environment.BG_COLOR
    environment.background_color = Color(0.46, 0.68, 0.80)
    environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    environment.ambient_light_color = Color(0.92, 0.95, 1.0)
    environment.ambient_light_energy = 0.70
    world.environment = environment
    stage.add_child(world)
    var sun := DirectionalLight3D.new()
    sun.rotation_degrees = Vector3(-43, -32, 0)
    sun.light_energy = 1.35
    sun.shadow_enabled = true
    stage.add_child(sun)
    var ground := MeshInstance3D.new()
    var plane := PlaneMesh.new()
    plane.size = Vector2(120, 120)
    ground.mesh = plane
    var ground_material := StandardMaterial3D.new()
    # Neutral ground cannot satisfy the leaf-green pixel gate. Earlier green
    # ground hid brown/grey palms by contributing unrelated passing samples.
    ground_material.albedo_color = Color(0.22, 0.22, 0.22)
    ground_material.roughness = 0.90
    ground.material_override = ground_material
    stage.add_child(ground)
    var filenames := ["road_palm.glb", "road_palm_short.glb", "road_palm_curved.glb", "road_tree_near.glb"]
    var positions := [Vector3(-12, 0, -7), Vector3(-5, 0, -4), Vector3(3, 0, -7), Vector3(10, 0, -4)]
    for index in range(filenames.size()):
        var mesh: ArrayMesh = visuals._reference_plant_mesh(filenames[index], 8.2)
        _check(mesh != null, filenames[index] + ": actual near model missing")
        if mesh == null:
            continue
        # Use the actual runtime MultiMesh path with explicit white tint.
        var instance := MultiMeshInstance3D.new()
        var multimesh := MultiMesh.new()
        multimesh.transform_format = MultiMesh.TRANSFORM_3D
        multimesh.use_colors = true
        multimesh.mesh = mesh
        multimesh.instance_count = 1
        multimesh.set_instance_transform(0, Transform3D.IDENTITY)
        multimesh.set_instance_color(0, Color.WHITE)
        instance.multimesh = multimesh
        instance.position = positions[index]
        stage.add_child(instance)
        plants[filenames[index]] = instance
    var car := CarModel.new()
    stage.add_child(car)
    car.build()
    car.position = Vector3(0, 0, 0)
    sedan = car
    camera = Camera3D.new()
    camera.fov = 55
    camera.current = true
    stage.add_child(camera)
    await _capture("foliage-wide", Vector3(19, 9, 23), Vector3(0, 3.8, -4))
    await _capture("palm-alpha-detail", Vector3(-8.0, 7.6, 1), Vector3(-5, 7.6, -4), true, "road_palm_short.glb")
    await _capture("tree-alpha-detail", Vector3(13, 5.6, 2), Vector3(10, 5.4, -4), true, "road_tree_near.glb")
    await _capture("sedan-front", Vector3(-4.6, 2.4, -7.5), Vector3(0, 0.72, -0.2))
    await _capture("sedan-rear", Vector3(4.6, 2.4, 7.5), Vector3(0, 0.72, 0.2))
    await _capture("sedan-side", Vector3(6.8, 1.8, -0.4), Vector3(0, 0.72, 0.0))
    print("YARDMAN_REFERENCE_FOLIAGE_RENDER %s frames=6 compatibility=1" % ("PASS" if failures == 0 else "FAIL"))
    stage.queue_free()
    await process_frame
    quit(failures)
