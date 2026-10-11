extends SceneTree

const Coastline = preload("res://scripts/coastline.gd")
var failures := 0
var output_dir := ""

func _initialize() -> void:
    call_deferred("_run")

func _check(ok: bool, message: String) -> void:
    if not ok:
        failures += 1
        push_error("WATER_MATERIAL_TEST: " + message)

func _payload() -> Dictionary:
    return {"water": PackedVector3Array([
        Vector3(0, 0, 0), Vector3(64, 0, 0), Vector3(0, 0, 64),
        Vector3(64, 0, 0), Vector3(64, 0, 64), Vector3(0, 0, 64)]),
        "shore_distance": PackedFloat32Array([40, 40, 40, 40, 40, 40])}

func _picture(name: String) -> Image:
    for frame in range(8):
        await process_frame
    await RenderingServer.frame_post_draw
    var picture := root.get_texture().get_image()
    if picture == null or picture.is_empty():
        _check(false, "Actual Compatibility frame absent")
        return null
    if not output_dir.is_empty():
        _check(picture.save_png(output_dir.path_join(name + ".png")) == OK, "Capture save failed")
    return picture

func _run() -> void:
    if DisplayServer.get_name() == "headless":
        _check(false, "Actual Compatibility display required")
        quit(1)
        return
    root.size = Vector2i(640, 360)
    output_dir = OS.get_environment("YARDMAN_WATER_CAPTURE_DIR")
    if not output_dir.is_empty():
        DirAccess.make_dir_recursive_absolute(output_dir)
    var world := Node3D.new()
    root.add_child(world)
    var environment := WorldEnvironment.new()
    environment.environment = Environment.new()
    environment.environment.background_mode = Environment.BG_COLOR
    environment.environment.background_color = Color(0.13, 0.20, 0.28)
    environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    environment.environment.ambient_light_color = Color(0.65, 0.74, 0.87)
    environment.environment.ambient_light_energy = 0.8
    world.add_child(environment)
    var light := DirectionalLight3D.new()
    light.rotation_degrees = Vector3(-35, 120, 0)
    light.light_energy = 1.1
    world.add_child(light)
    var coast := Coastline.new()
    world.add_child(coast)
    # Compile the same fragment with a constant clock for a reproducible rebase.
    var frozen := Shader.new()
    frozen.code = coast.water_material.shader.code.replace("TIME", "0.0")
    coast.water_material.shader = frozen
    var source_bound := bool(coast.water_material.get_shader_parameter("has_reference_surface"))
    var reference_required := OS.get_environment("YARDMAN_REQUIRE_REFERENCE") == "1"
    if reference_required:
        _check(source_bound, "Required private water surface was not bound")
    var origin := Vector2(-33049.639, -48530.022)
    var left := Node3D.new()
    var right := Node3D.new()
    world.add_child(left)
    world.add_child(right)
    right.position.x = 64.0
    var a := coast.append_water(_payload(), left, origin.x, origin.y)
    var b := coast.append_water(_payload(), right, origin.x + 64, origin.y)
    var aa := a.mesh.surface_get_arrays(0)
    var bb := b.mesh.surface_get_arrays(0)
    var seam_matches := 0
    for ia in aa[Mesh.ARRAY_VERTEX].size():
        var av: Vector3 = aa[Mesh.ARRAY_VERTEX][ia]
        _check(av.y == 0.0, "Canonical sea level moved")
        for ib in bb[Mesh.ARRAY_VERTEX].size():
            var bv: Vector3 = bb[Mesh.ARRAY_VERTEX][ib]
            if av.is_equal_approx(bv + right.position):
                seam_matches += 1
                _check(aa[Mesh.ARRAY_TEX_UV][ia].is_equal_approx(bb[Mesh.ARRAY_TEX_UV][ib]), "Streamed UV seam")
                _check(aa[Mesh.ARRAY_COLOR][ia].is_equal_approx(bb[Mesh.ARRAY_COLOR][ib]), "Streamed shore attribute seam")
    _check(seam_matches > 0, "Adjacent ocean fixtures share no edges")
    var camera := Camera3D.new()
    world.add_child(camera)
    camera.position = Vector3(64, 12, 86)
    camera.look_at(Vector3(64, 0, 20))
    camera.fov = 68
    camera.current = true
    var before := await _picture("water-before-rebase")
    if before == null:
        world.queue_free()
        await process_frame
        quit(1)
        return
    var shift := Vector3(-768, 0, 512)
    left.position += shift
    right.position += shift
    camera.position += shift
    var after := await _picture("water-after-rebase")
    if after == null:
        world.queue_free()
        await process_frame
        quit(1)
        return
    var sum_difference := 0.0
    for y in before.get_height():
        for x in before.get_width():
            var p := before.get_pixel(x, y)
            var q := after.get_pixel(x, y)
            sum_difference += absf(p.r-q.r) + absf(p.g-q.g) + absf(p.b-q.b)
    var difference := sum_difference / float(before.get_width() * before.get_height() * 3)
    _check(difference < 0.005, "Frozen water changed under origin rebase: " + str(difference))
    for flag in ["has_reference_surface", "has_reference_foam", "has_reference_caustics"]:
        coast.water_material.set_shader_parameter(flag, false)
    var fallback := await _picture("water-fallback")
    if fallback == null:
        world.queue_free()
        await process_frame
        quit(1)
        return
    var source_difference := 0.0
    for y in after.get_height():
        for x in after.get_width():
            var p := after.get_pixel(x, y)
            var q := fallback.get_pixel(x, y)
            source_difference += absf(p.r-q.r) + absf(p.g-q.g) + absf(p.b-q.b)
    source_difference /= float(after.get_width() * after.get_height() * 3)
    if source_bound:
        _check(source_difference > 0.0001, "Bound source colour detail had no visible effect")
    if failures == 0:
        print("YARDMAN_WATER_MATERIAL_TEST PASS actual_gl_frames=3 adjacent_uv_seam=1 sea_level=0 shore_channels=1 rebase_pixel_mean=%.8f source_detail_mean=%.8f private_pack=%d reference_required=%d scope=%s renderer=%s" % [difference, source_difference, int(source_bound), int(reference_required), "private_source_and_fallback" if source_bound else "asset_absent_fallback_only", RenderingServer.get_video_adapter_name()])
    world.queue_free()
    await process_frame
    quit(0 if failures == 0 else 1)
