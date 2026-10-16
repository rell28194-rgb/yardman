extends SceneTree

# Actual Compatibility render fixture for optional owner-supplied road/street props.
# Public CI may run without the private pack; that fallback does not accept private quality.
const References = preload("res://scripts/reference_assets.gd")
const PROP_FILES := [
    "road_concrete_barrier.glb",
    "road_portable_fence.glb",
    "settlement_fire_hydrant.glb",
    "settlement_metal_cabinet.glb",
    "settlement_waste_bin.glb",
]

var failures := 0
var stage: Node3D
var camera: Camera3D
var output := ""

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("REFERENCE_ROAD_PROPS_RENDER: " + message)

func _expand_bounds(node: Node, parent_pose: Transform3D, result: Dictionary) -> void:
    var pose := parent_pose
    if node is Node3D:
        pose = parent_pose * (node as Node3D).transform
    if node is MeshInstance3D:
        var instance := node as MeshInstance3D
        if instance.mesh != null:
            result.surfaces = int(result.surfaces) + instance.mesh.get_surface_count()
            var bounds := instance.mesh.get_aabb()
            for ix in range(2):
                for iy in range(2):
                    for iz in range(2):
                        var local := bounds.position + Vector3(bounds.size.x * ix, bounds.size.y * iy, bounds.size.z * iz)
                        var point: Vector3 = pose * local
                        _check(is_finite(point.x) and is_finite(point.y) and is_finite(point.z), "non-finite imported bound")
                        if not bool(result.valid):
                            result.minimum = point
                            result.maximum = point
                            result.valid = true
                        else:
                            var minimum: Vector3 = result.minimum
                            var maximum: Vector3 = result.maximum
                            result.minimum = Vector3(minf(minimum.x, point.x), minf(minimum.y, point.y), minf(minimum.z, point.z))
                            result.maximum = Vector3(maxf(maximum.x, point.x), maxf(maximum.y, point.y), maxf(maximum.z, point.z))
    for child in node.get_children():
        _expand_bounds(child, pose, result)

func _frame() -> Image:
    var image := get_root().get_texture().get_image()
    _check(image != null, "renderer returned no frame")
    return image

func _changed_samples(before: Image, after: Image) -> int:
    if before == null or after == null:
        return 0
    _check(before.get_size() == after.get_size(), "baseline/frame size mismatch")
    var changed := 0
    for y in range(20, after.get_height() - 20, 2):
        for x in range(20, after.get_width() - 20, 2):
            var a := before.get_pixel(x, y)
            var b := after.get_pixel(x, y)
            if absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) > 0.055:
                changed += 1
    return changed

func _validate_and_capture(filename: String, packed: PackedScene) -> void:
    var source := packed.instantiate() as Node3D
    _check(source != null, filename + ": did not instantiate as Node3D")
    if source == null:
        return
    stage.add_child(source)
    var result := {"valid": false, "minimum": Vector3.ZERO, "maximum": Vector3.ZERO, "surfaces": 0}
    _expand_bounds(source, Transform3D.IDENTITY, result)
    _check(bool(result.valid), filename + ": has no finite mesh bounds")
    _check(int(result.surfaces) > 0, filename + ": has no mesh surfaces")
    if not bool(result.valid):
        source.queue_free()
        await process_frame
        return
    var minimum: Vector3 = result.minimum
    var maximum: Vector3 = result.maximum
    var extents := maximum - minimum
    var max_extent := maxf(extents.x, maxf(extents.y, extents.z))
    _check(max_extent > 0.15 and max_extent < 20.0, filename + ": implausible metre-scale extent " + str(max_extent))
    _check(extents.y > 0.15 and extents.y < 5.0, filename + ": implausible vertical extent " + str(extents.y))
    var center := (minimum + maximum) * 0.5
    var radius := maxf(max_extent, 0.5)
    camera.position = center + Vector3(radius * 1.45, radius * 0.62, radius * 1.75)
    camera.look_at(center)
    source.visible = false
    for frame in range(4):
        await process_frame
    await RenderingServer.frame_post_draw
    var baseline := _frame()
    source.visible = true
    for frame in range(8):
        await process_frame
    await RenderingServer.frame_post_draw
    var rendered := _frame()
    var changed := _changed_samples(baseline, rendered)
    _check(changed > 180, filename + ": rendered source does not measurably change isolated frame")
    if rendered != null:
        var capture_path := output.path_join(filename.get_basename() + ".png")
        _check(rendered.save_png(capture_path) == OK, "could not save " + capture_path)
    print("YARDMAN_REFERENCE_ROAD_PROP_FRAME asset=%s surfaces=%d max_extent=%.4f changed_samples=%d" % [filename, int(result.surfaces), max_extent, changed])
    source.queue_free()
    await process_frame

func _run() -> void:
    if DisplayServer.get_name() == "headless":
        push_error("reference_road_props_render_test requires an actual GL display")
        quit(1)
        return
    var required := OS.get_environment("YARDMAN_REQUIRE_REFERENCE") == "1"
    output = OS.get_environment("YARDMAN_RENDER_OUTPUT_DIR")
    if output.is_empty():
        output = "user://reference-road-props"
    DirAccess.make_dir_recursive_absolute(output)
    var first: PackedScene = References.scene(PROP_FILES[0])
    if first == null:
        _check(not required, "required private road-prop pack is missing")
        print("YARDMAN_REFERENCE_ROAD_PROPS_RENDER %s private_pack=0 fallback=1" % ("PASS" if failures == 0 else "FAIL"))
        quit(failures)
        return
    stage = Node3D.new()
    root.add_child(stage)
    var world := WorldEnvironment.new()
    var environment := Environment.new()
    environment.background_mode = Environment.BG_COLOR
    environment.background_color = Color(0.33, 0.38, 0.42)
    environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    environment.ambient_light_color = Color(0.92, 0.95, 1.0)
    environment.ambient_light_energy = 0.62
    world.environment = environment
    stage.add_child(world)
    var sun := DirectionalLight3D.new()
    sun.rotation_degrees = Vector3(-42.0, -35.0, 0.0)
    sun.light_energy = 1.45
    sun.shadow_enabled = true
    stage.add_child(sun)
    camera = Camera3D.new()
    camera.current = true
    camera.fov = 48.0
    camera.near = 0.05
    camera.far = 100.0
    stage.add_child(camera)
    for filename: String in PROP_FILES:
        var packed: PackedScene = References.scene(filename)
        _check(packed != null, filename + ": private scene missing/import failed")
        if packed != null:
            await _validate_and_capture(filename, packed)
    print("YARDMAN_REFERENCE_ROAD_PROPS_RENDER %s assets=%d compatibility=1" % [("PASS" if failures == 0 else "FAIL"), PROP_FILES.size()])
    stage.queue_free()
    await process_frame
    quit(failures)
