extends SceneTree

# Actual GL material/winding inspection. These declared synthetic footprints
# isolate the streamed building renderer; this is not a Jamaican city capture.
const Coordinates = preload("res://scripts/world_coordinates.gd")
const Buildings = preload("res://scripts/building_streamer.gd")
const Visuals = preload("res://scripts/world_visuals.gd")
var failures := 0
var streamer
var camera: Camera3D
var output_dir := ""

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("BUILDING_RENDER_TEST: " + message)

func _house(identifier: String, x: float, z: float, source := 3) -> Array:
    return [identifier, 4.4, source, 0, 4.4,
        [[[x, 0, z], [x + 12, 0, z], [x + 12, 0, z + 16], [x, 0, z + 16]]],
        [[x, z], [x + 12, z], [x + 12, z + 16], [x, z + 16]], [0, 2, 1, 0, 3, 2]]

func _write_fixture(directory: String) -> void:
    DirAccess.make_dir_recursive_absolute(directory)
    var records := [_house("w21:0", 0, 0), _house("w24:0", 17, 0), _house("w29:0", 34, 0, 1)]
    var payload := JSON.stringify(records).to_utf8_buffer().compress(FileAccess.COMPRESSION_GZIP)
    var file := FileAccess.open(directory + "/fixture.ymb", FileAccess.WRITE)
    file.store_buffer("YMB1".to_ascii_buffer())
    file.store_32(1)
    file.store_16(0)
    file.store_16(0)
    file.store_32(20)
    file.store_32(payload.size())
    file.store_buffer(payload)
    file.close()
    file = FileAccess.open(directory + "/manifest.json", FileAccess.WRITE)
    file.store_string(JSON.stringify({"format": 1, "crs": "EPSG:3448",
        "origin": {"easting": 100000.0, "northing": 200000.0}, "tile_size": 4096, "cell_size": 256,
        "stats": {"buildings": 3, "cells": 1},
        "tiles": [{"x": 0, "z": 0, "file": "fixture.ymb", "cells": [[0, 0]]}]}))
    file.close()

func _capture(label: String) -> void:
    for frame in range(12):
        await process_frame
    await RenderingServer.frame_post_draw
    var picture := root.get_texture().get_image()
    _check(picture != null and not picture.is_empty(), "No GL-rendered building image")
    if picture == null or picture.is_empty():
        return
    _check(picture.save_png(output_dir.path_join(label + ".png")) == OK, "Could not save real building render")
    var lit_roof_pixels := 0
    # The pitched roof is viewed from above. An inverted culled roof exposes
    # the dark interior, and the earlier double-sided version had black roofs.
    for position: Vector3 in [Vector3(6, 4.1, 5), Vector3(23, 4.1, 5)]:
        var screen := camera.unproject_position(position)
        for dy in range(-2, 3):
            for dx in range(-2, 3):
                var x := clampi(roundi(screen.x) + dx, 0, picture.get_width() - 1)
                var y := clampi(roundi(screen.y) + dy, 0, picture.get_height() - 1)
                var pixel := picture.get_pixel(x, y)
                if maxf(pixel.r, maxf(pixel.g, pixel.b)) > 0.16:
                    lit_roof_pixels += 1
    _check(lit_roof_pixels >= 20, "Roof lighting/culling regression: %d lit roof pixels" % lit_roof_pixels)

func _run() -> void:
    if DisplayServer.get_name() == "headless":
        _check(false, "An actual GL display is required")
        quit(1)
        return
    output_dir = OS.get_environment("YARDMAN_BUILDING_CAPTURE_DIR")
    if output_dir.is_empty():
        output_dir = ProjectSettings.globalize_path("res://build/building-captures")
    DirAccess.make_dir_recursive_absolute(output_dir)
    var directory := "user://yardman/tests/building_render"
    _write_fixture(directory)
    var coordinates := Coordinates.new()
    coordinates.configure({"origin": {"easting": 100000.0, "northing": 200000.0}, "tile_size": 4096})
    var stage := Node3D.new()
    root.add_child(stage)
    streamer = Buildings.new()
    streamer.configure(directory, coordinates)
    stage.add_child(streamer)
    streamer.update_world(20, 8, true)
    for frame in range(600):
        await process_frame
        if streamer.is_idle():
            break
    _check(streamer._loaded.has("0:0"), "Fixture did not stream")
    if OS.get_environment("YARDMAN_REQUIRE_REFERENCE") == "1":
        _check(bool(streamer._wall_material.get_shader_parameter("has_reference_plaster")), "Personal pack plaster is not bound")
        _check(bool(streamer._roof_material.get_shader_parameter("has_reference_tiles")), "Personal pack tiled roof is not bound")
    var environment := Environment.new()
    var world := WorldEnvironment.new()
    world.environment = environment
    stage.add_child(world)
    var sun := DirectionalLight3D.new()
    stage.add_child(sun)
    var visuals := Visuals.new()
    visuals.configure_environment(environment, sun)
    visuals.update_daylight(10.0, environment)
    sun.shadow_enabled = true
    var floor_mesh := PlaneMesh.new()
    floor_mesh.size = Vector2(130, 100)
    var floor_material := StandardMaterial3D.new()
    floor_material.albedo_color = Color(0.28, 0.36, 0.22)
    floor_material.roughness = 0.95
    var floor_instance := MeshInstance3D.new()
    floor_instance.mesh = floor_mesh
    floor_instance.material_override = floor_material
    floor_instance.position = Vector3(23, -0.015, 8)
    stage.add_child(floor_instance)
    camera = Camera3D.new()
    stage.add_child(camera)
    camera.current = true
    camera.position = Vector3(29, 17, 38)
    camera.look_at(Vector3(22, 2.0, 7))
    camera.fov = 65
    await _capture("building-materials-front")
    camera.position = Vector3(-20, 13, 28)
    camera.look_at(Vector3(10, 2, 7))
    await _capture("building-materials-side")
    print("YARDMAN_BUILDING_RENDER_TEST %s actual_gl_frames=2 source_and_inferred_roofs=1 renderer=%s" %
        ["PASS" if failures == 0 else "FAIL", RenderingServer.get_video_adapter_name()])
    stage.queue_free()
    await process_frame
    quit(0 if failures == 0 else 1)
