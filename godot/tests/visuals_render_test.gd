extends SceneTree

# Optional rendered material inspection; no geodata or phone benchmark claim.
const Visuals = preload("res://scripts/world_visuals.gd")
const CarModel = preload("res://scripts/vehicle_model.gd")
var stage: Node3D

func _initialize() -> void:
    call_deferred("_run")

func _height(x: float, z: float) -> float:
    return 30.0 + sin(x * 0.009) * cos(z * 0.012) * 2.2

func _run() -> void:
    if DisplayServer.get_name() == "headless":
        push_error("visuals_render_test requires an actual GL display, such as Xvfb")
        quit(1)
        return
    stage = Node3D.new()
    get_root().add_child(stage)
    var visuals := Visuals.new()
    visuals.quality = "Ultra"
    var environment := Environment.new()
    var world := WorldEnvironment.new()
    world.environment = environment
    stage.add_child(world)
    var sun := DirectionalLight3D.new()
    stage.add_child(sun)
    visuals.configure_environment(environment, sun)
    visuals.update_daylight(10.0, environment)
    sun.shadow_enabled = true
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var indices := PackedInt32Array()
    for z in range(65):
        for x in range(65):
            var sx := float(x) * 8.0
            var sz := float(z) * 8.0
            vertices.append(Vector3(sx, _height(sx, sz), sz))
            var dx := (_height(sx - 1.0, sz) - _height(sx + 1.0, sz)) * 0.5
            var dz := (_height(sx, sz - 1.0) - _height(sx, sz + 1.0)) * 0.5
            normals.append(Vector3(dx, 1.0, dz).normalized())
            if x < 64 and z < 64:
                var a := z * 65 + x
                indices.append_array(PackedInt32Array([a, a + 1, a + 65, a + 1, a + 66, a + 65]))
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = normals
    arrays[Mesh.ARRAY_INDEX] = indices
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    mesh.surface_set_material(0, visuals.terrain_material(Vector2.ZERO))
    var ground := MeshInstance3D.new()
    ground.mesh = mesh
    stage.add_child(ground)
    var segments: Array = []
    for i in range(80):
        var z := float(i) * 6.0 + 20.0
        segments.append([250.0, z, 250.0, z + 6.0, 7.0, 40.0, 0, str(i), "edge", 30.0, 30.0])
    visuals.make_roadside(stage, segments, Vector2i.ZERO, 4096.0, _height)
    var car := CarModel.new()
    stage.add_child(car)
    car.build()
    car.position = Vector3(250.0, _height(250.0, 250.0), 250.0)
    var palm := MeshInstance3D.new()
    palm.mesh = visuals._reference_plant_mesh("road_palm.glb", 14.5)
    if palm.mesh == null:
        palm.mesh = visuals._make_palm_mesh()
    palm.position = Vector3(244.0, _height(244.0, 232.0), 232.0)
    stage.add_child(palm)
    var tree := MeshInstance3D.new()
    tree.mesh = visuals._reference_plant_mesh("road_tree_near.glb", 8.2)
    if tree.mesh == null:
        tree.mesh = visuals._make_broadleaf_mesh()
    tree.position = Vector3(261.0, _height(261.0, 225.0), 225.0)
    stage.add_child(tree)

    # Deterministic GL regression probe: exercise the same MultiMesh COLOR and
    # INSTANCE_CUSTOM inputs used by streamed roadside foliage, but sample it
    # at its actual projected screen position instead of a stale hard-coded
    # camera rectangle. This still fails if Compatibility renders crowns black.
    var foliage_probe_mesh := visuals._make_broadleaf_mesh()
    var foliage_probe_multi := MultiMesh.new()
    foliage_probe_multi.transform_format = MultiMesh.TRANSFORM_3D
    foliage_probe_multi.use_colors = true
    foliage_probe_multi.use_custom_data = true
    foliage_probe_multi.mesh = foliage_probe_mesh
    foliage_probe_multi.instance_count = 1
    foliage_probe_multi.set_instance_transform(0, Transform3D.IDENTITY)
    foliage_probe_multi.set_instance_color(0, Color.WHITE)
    foliage_probe_multi.set_instance_custom_data(0, Color(0.23, 0.71, 0.18, 1.0))
    var foliage_probe := MultiMeshInstance3D.new()
    foliage_probe.name = "GLFoliageProbe"
    foliage_probe.multimesh = foliage_probe_multi
    foliage_probe.position = Vector3(246.0, _height(246.0, 239.0), 239.0)
    stage.add_child(foliage_probe)

    var camera := Camera3D.new()
    stage.add_child(camera)
    camera.position = car.position + Vector3(6.0, 3.9, 7.0)
    camera.look_at(car.position + Vector3(0.0, 1.2, 0.0))
    camera.fov = 62.0
    camera.current = true
    for frame in range(12):
        await process_frame
    await RenderingServer.frame_post_draw
    var target := OS.get_environment("YARDMAN_RENDER_OUTPUT")
    if target.is_empty():
        target = "user://visual-polish.png"
    var capture := get_root().get_texture().get_image()
    var save_error := capture.save_png(target)
    if save_error != OK:
        push_error("Could not save GL visual regression capture: %s" % error_string(save_error))
        quit(save_error)
        return

    if camera.is_position_behind(foliage_probe.global_position + Vector3(0.0, 6.0, 0.0)):
        push_error("GL foliage probe unexpectedly behind camera")
        quit(1)
        return
    var probe_screen := camera.unproject_position(foliage_probe.global_position + Vector3(0.0, 6.0, 0.0))
    var colored_foliage := 0
    var min_x := clampi(int(round(probe_screen.x)) - 90, 0, capture.get_width() - 1)
    var max_x := clampi(int(round(probe_screen.x)) + 90, 0, capture.get_width() - 1)
    var min_y := clampi(int(round(probe_screen.y)) - 110, 0, capture.get_height() - 1)
    var max_y := clampi(int(round(probe_screen.y)) + 90, 0, capture.get_height() - 1)
    for y in range(min_y, max_y + 1):
        for x in range(min_x, max_x + 1):
            var pixel := capture.get_pixel(x, y)
            if pixel.g > maxf(pixel.r, pixel.b) * 1.12 and pixel.g > 0.20:
                colored_foliage += 1
    if colored_foliage < 20:
        push_error("GL foliage color regression: only %d green probe pixels near %s" % [colored_foliage, probe_screen])
        quit(1)
        return
    print("YARDMAN_VISUALS_RENDER PASS %s foliage_probe_pixels=%d" % [target, colored_foliage])
    quit(OK)
