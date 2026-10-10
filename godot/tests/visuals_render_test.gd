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
                indices.append_array(PackedInt32Array([a, a + 65, a + 1, a + 1, a + 65, a + 66]))
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
    palm.mesh = visuals._make_palm_mesh()
    palm.position = Vector3(244.0, _height(244.0, 232.0), 232.0)
    stage.add_child(palm)
    var tree := MeshInstance3D.new()
    tree.mesh = visuals._make_broadleaf_mesh()
    tree.position = Vector3(261.0, _height(261.0, 225.0), 225.0)
    stage.add_child(tree)
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
    var colored_foliage := 0
    # The right horizon contains the actual MultiMesh tree crowns, excluding
    # the separately drawn foreground palm and the ground. Their first GL
    # render was entirely black despite a passing dummy-renderer boot.
    for y in range(150, 221):
        for x in range(890, 1101):
            var pixel := capture.get_pixel(x, y)
            if pixel.g > maxf(pixel.r, pixel.b) * 1.12 and pixel.g > 0.20:
                colored_foliage += 1
    if colored_foliage < 20:
        push_error("GL foliage color regression: only %d green crown pixels" % colored_foliage)
        quit(1)
        return
    var error := capture.save_png(target)
    if error == OK:
        print("YARDMAN_VISUALS_RENDER PASS ", target)
    quit(error)
