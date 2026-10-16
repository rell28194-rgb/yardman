extends SceneTree

# Generated 192 m fixture exercises the production terrain rebuild and active
# terrain shader. These captures prove this cut case, not national geography.
const Corridor = preload("res://scripts/road_corridor_terrain_runtime.gd")
const Registry = preload("res://scripts/render_material_registry.gd")
const SIZE := Vector2i(960, 540)
const RESOLUTION := 4
const SPACING := 64.0
const DECK_Y := 10.0
var failures := 0
var output_dir := ""
var land: MeshInstance3D
var fixture_camera: Camera3D
var report: Dictionary = {}

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("ROAD_CORRIDOR_RENDER_TEST: " + message)

func _source(heights: PackedFloat32Array) -> ArrayMesh:
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var colors := PackedColorArray()
    var indices := PackedInt32Array()
    for z in range(RESOLUTION):
        for x in range(RESOLUTION):
            vertices.append(Vector3(x * SPACING, heights[z * RESOLUTION + x], z * SPACING))
            normals.append(Vector3(-0.025, 1.0, -0.05).normalized())
            colors.append(Color(0.25, 0.4, 0.15))
    for z in range(RESOLUTION - 1):
        for x in range(RESOLUTION - 1):
            var a := z * RESOLUTION + x
            indices.append_array(PackedInt32Array([a, a + 1, a + RESOLUTION, a + 1, a + RESOLUTION + 1, a + RESOLUTION]))
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = normals
    arrays[Mesh.ARRAY_COLOR] = colors
    arrays[Mesh.ARRAY_INDEX] = indices
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    return mesh

func _height_on_mesh(arrays: Array, point: Vector2) -> float:
    var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
    var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
    var highest := -INF
    for offset in range(0, indices.size(), 3):
        var a: Vector3 = vertices[indices[offset]]
        var b: Vector3 = vertices[indices[offset + 1]]
        var c: Vector3 = vertices[indices[offset + 2]]
        var pa := Vector2(a.x, a.z)
        var pb := Vector2(b.x, b.z)
        var pc := Vector2(c.x, c.z)
        var denominator := (pb - pa).cross(pc - pa)
        if absf(denominator) < 0.00001:
            continue
        var u := (point - pa).cross(pc - pa) / denominator
        var v := (pb - pa).cross(point - pa) / denominator
        if u >= -0.00001 and v >= -0.00001 and u + v <= 1.00001:
            highest = maxf(highest, a.y + u * (b.y - a.y) + v * (c.y - a.y))
    return highest

func _box(parent: Node3D, position: Vector3, dimensions: Vector3, color: Color) -> void:
    var node := MeshInstance3D.new()
    var mesh := BoxMesh.new()
    mesh.size = dimensions
    var material := StandardMaterial3D.new()
    material.albedo_color = color
    material.roughness = 0.9
    node.mesh = mesh
    node.material_override = material
    node.position = position
    parent.add_child(node)

func _scene(source: ArrayMesh) -> void:
    var scene := Node3D.new()
    root.add_child(scene)
    var env := WorldEnvironment.new()
    env.environment = Environment.new()
    env.environment.background_mode = Environment.BG_COLOR
    env.environment.background_color = Color(0.1, 0.17, 0.23)
    env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    env.environment.ambient_light_color = Color(0.75, 0.82, 0.9)
    env.environment.ambient_light_energy = 0.6
    scene.add_child(env)
    var sun := DirectionalLight3D.new()
    sun.rotation_degrees = Vector3(-55, -30, 0)
    sun.light_energy = 1.3
    scene.add_child(sun)
    var camera := Camera3D.new()
    camera.position = Vector3(215, 145, 230)
    camera.fov = 47
    scene.add_child(camera)
    camera.look_at(Vector3(96, 9, 96))
    camera.current = true
    fixture_camera = camera
    land = MeshInstance3D.new()
    land.mesh = source
    var material := ShaderMaterial.new()
    material.shader = Registry.shader_for("terrain", "", "Quality")
    material.set_shader_parameter("terrain_tile_size", 192.0)
    var noise := Image.create(4, 4, false, Image.FORMAT_RGB8)
    noise.fill(Color(0.52, 0.5, 0.5))
    material.set_shader_parameter("surface_noise", ImageTexture.create_from_image(noise))
    land.material_override = material
    scene.add_child(land)
    _box(scene, Vector3(96, DECK_Y - 0.15, 96), Vector3(176, 0.3, 8), Color(0.08, 0.09, 0.11))
    # Distinct centre marking makes before/after deck visibility reviewable.
    _box(scene, Vector3(96, DECK_Y + 0.015, 96), Vector3(174, 0.03, 0.22), Color(0.95, 0.78, 0.08))

func _capture(name: String) -> Image:
    for frame in range(12):
        await process_frame
    await RenderingServer.frame_post_draw
    var image := root.get_texture().get_image()
    _check(image != null and not image.is_empty(), "No actual renderer image for " + name)
    if image != null and not image.is_empty():
        _check(image.save_png(output_dir.path_join(name + ".png")) == OK, "Capture save failed")
    return image

func _run() -> void:
    if DisplayServer.get_name() == "headless":
        push_error("ROAD_CORRIDOR_RENDER_TEST requires an actual display")
        quit(2)
        return
    await process_frame
    paused = false
    for child in root.get_children():
        child.process_mode = Node.PROCESS_MODE_DISABLED
    for canvas in root.find_children("*", "CanvasLayer", true, false):
        canvas.visible = false
    root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
    root.content_scale_size = Vector2i.ZERO
    root.size = SIZE
    root.scaling_3d_scale = 1.0
    output_dir = OS.get_environment("YARDMAN_RENDER_CAPTURE_DIR")
    if output_dir.is_empty():
        output_dir = ProjectSettings.globalize_path("user://road-corridor-captures")
    _check(DirAccess.make_dir_recursive_absolute(output_dir) == OK, "Cannot create capture directory")
    var actual := RenderingServer.get_current_rendering_method()
    var expected := OS.get_environment("YARDMAN_EXPECT_RENDER_METHOD")
    _check(not expected.is_empty() and actual == expected, "Renderer fallback or missing expected renderer")
    var heights := PackedFloat32Array()
    for z in range(RESOLUTION):
        for x in range(RESOLUTION):
            heights.append(14.0 + float(x) * SPACING * 0.025 + float(z) * SPACING * 0.05)
    var source := _source(heights)
    var road := [8.0, 96.0, 184.0, 96.0, 8.0, 5, 0, "road", 0, DECK_Y, DECK_Y,
        [[8.0, DECK_Y, 92.0], [8.0, DECK_Y, 100.0], [184.0, DECK_Y, 100.0], [184.0, DECK_Y, 92.0]]]
    var runtime := Corridor.new()
    var mask := PackedByteArray([1, 1, 1, 1, 1, 1, 1, 1, 1])
    var plan := runtime.refinement_plan([road], Vector2i.ZERO, 192.0, SPACING, RESOLUTION, mask)
    var rebuilt := runtime.rebuild_land_arrays(source, heights, plan.cells, Vector2i.ZERO, 192.0, SPACING, RESOLUTION)
    _check(bool(rebuilt.get("ok", false)), "Production terrain rebuild failed")
    if not bool(rebuilt.get("ok", false)):
        runtime.free()
        quit(2)
        return
    var vertices: PackedVector3Array = rebuilt.arrays[Mesh.ARRAY_VERTEX]
    var normals: PackedVector3Array = rebuilt.arrays[Mesh.ARRAY_NORMAL]
    var indices: PackedInt32Array = rebuilt.arrays[Mesh.ARRAY_INDEX]
    _check(vertices.size() == normals.size(), "Normals missing")
    for i in range(vertices.size()):
        _check(vertices[i].is_finite() and normals[i].is_finite() and absf(normals[i].length() - 1.0) < 0.01, "Invalid vertex or normal")
    for index in indices:
        _check(index >= 0 and index < vertices.size(), "Triangle index out of bounds")
    var maximum_under_deck := -INF
    var under_deck_samples := 0
    for x in range(8, 185, 2):
        for z in range(92, 101):
            maximum_under_deck = maxf(maximum_under_deck, _height_on_mesh(rebuilt.arrays, Vector2(x, z)))
            under_deck_samples += 1
    _check(maximum_under_deck <= DECK_Y - 0.01, "Refined terrain triangles still penetrate the 8m road deck: y=%.4f" % maximum_under_deck)
    var far_before := _height_on_mesh(source.surface_get_arrays(0), Vector2(32, 16))
    var far_after := _height_on_mesh(rebuilt.arrays, Vector2(32, 16))
    _check(absf(far_after - far_before) < 0.00001, "Terrain outside the road corridor changed")
    var refined := ArrayMesh.new()
    refined.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, rebuilt.arrays)
    _check(source.get_aabb().position.x == refined.get_aabb().position.x and source.get_aabb().end.z == refined.get_aabb().end.z, "Terrain plan extent changed")
    _scene(source)
    var coarse_image := await _capture("coarse")
    land.mesh = refined
    var refined_image := await _capture("refined")
    var changed_pixels := 0
    var visible_road_samples := 0
    var road_image_samples := 0
    if coarse_image != null and refined_image != null:
        _check(coarse_image.get_size() == SIZE and refined_image.get_size() == SIZE, "Capture dimensions wrong")
        for y in range(0, SIZE.y, 2):
            for x in range(0, SIZE.x, 2):
                var a := coarse_image.get_pixel(x, y)
                var b := refined_image.get_pixel(x, y)
                if Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length() > 0.04:
                    changed_pixels += 1
        _check(changed_pixels > 100, "Refinement did not produce a measurable visible change")
        # Sample both lanes away from the centre marking. A merely changed
        # terrain image does not prove that the narrow road actually emerged.
        for x in range(24, 169, 12):
            for z in [94.0, 98.0]:
                var pixel := fixture_camera.unproject_position(Vector3(x, DECK_Y + 0.02, z))
                var color := refined_image.get_pixel(clampi(roundi(pixel.x), 0, SIZE.x - 1), clampi(roundi(pixel.y), 0, SIZE.y - 1))
                if color.r < 0.33 and color.g < 0.33 and color.b < 0.33:
                    visible_road_samples += 1
                road_image_samples += 1
        _check(visible_road_samples >= road_image_samples - 2, "Road lanes remain obscured in actual capture: %d/%d visible" % [visible_road_samples, road_image_samples])
    report = {"scope": "generated 192m cut fixture, no Jamaica geographic or Android-device acceptance", "engine": Engine.get_version_info(),
        "method": actual, "adapter": RenderingServer.get_video_adapter_name(), "terrain_shader": land.material_override.shader.resource_path,
        "road_width_m": 8, "refinement_m": 8, "refined_cells": plan.cells.size(), "triangles": indices.size() / 3,
        "under_deck_samples": under_deck_samples, "maximum_terrain_under_deck_m": maximum_under_deck,
        "deck_height_m": DECK_Y, "far_terrain_before_m": far_before, "far_terrain_after_m": far_after,
        "changed_sampled_pixels": changed_pixels, "visible_road_samples": visible_road_samples, "road_image_samples": road_image_samples, "failures": failures}
    var file := FileAccess.open(output_dir.path_join("report.json"), FileAccess.WRITE)
    if file != null:
        file.store_string(JSON.stringify(report, "  "))
        file.close()
    runtime.free()
    print("YARDMAN_ROAD_CORRIDOR_RENDER_TEST %s %s" % ["PASS" if failures == 0 else "FAIL", JSON.stringify(report)])
    quit(0 if failures == 0 else 2)
