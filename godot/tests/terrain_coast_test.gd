extends SceneTree

const Terrain = preload("res://scripts/terrain_streamer.gd")
const Visuals = preload("res://scripts/world_visuals.gd")
var failures := 0
var camera: Camera3D

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error(message)

func _write(path: String, bytes: PackedByteArray) -> void:
    var file := FileAccess.open(path, FileAccess.WRITE)
    file.store_buffer(bytes)
    file.close()

func _json(path: String, value: Dictionary) -> void:
    _write(path, JSON.stringify(value).to_utf8_buffer())

func _check_clockwise(mesh: ArrayMesh, label: String) -> void:
    var arrays := mesh.surface_get_arrays(0)
    var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
    var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
    var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
    for triangle in range(0, indices.size(), 3):
        var a: int = indices[triangle]
        var b: int = indices[triangle + 1]
        var c: int = indices[triangle + 2]
        var cross := (vertices[b] - vertices[a]).cross(vertices[c] - vertices[a])
        if cross.length_squared() > 0.000000001:
            _check(normals[a].y > 0.0 and cross.dot(normals[a]) < 0.0,
                label + " has an inverted front face or downward shading normal")

func _render_land(terrain, root_node: Node3D, label: String) -> void:
    if DisplayServer.get_name() == "headless":
        return
    var land := root_node.get_node("RegisteredLand" if label == "near" else "OverviewLand") as MeshInstance3D
    var water := root_node.get_node("RegisteredOcean") as MeshInstance3D
    var land_material := StandardMaterial3D.new()
    land_material.albedo_color = Color(0.26, 0.66, 0.31)
    land_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    # StandardMaterial's default back-face culling proves the actual render
    # side, independently from an attractive procedural shader or ambient light.
    land.material_override = land_material
    var water_material := StandardMaterial3D.new()
    water_material.albedo_color = Color(0.08, 0.20, 0.60)
    water_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    water.material_override = water_material
    if camera == null:
        camera = Camera3D.new()
        root.add_child(camera)
        camera.current = true
        camera.position = Vector3(64, 220, 64)
        camera.look_at(Vector3(64, 0, 64), Vector3.FORWARD)
        camera.fov = 65
    for frame in range(4):
        await process_frame
    await RenderingServer.frame_post_draw
    var image := root.get_texture().get_image()
    var output := OS.get_environment("YARDMAN_TERRAIN_CAPTURE_DIR")
    if not output.is_empty():
        DirAccess.make_dir_recursive_absolute(output)
        image.save_png(output.path_join("terrain-coast-" + label + ".png"))
    for point: Vector3 in [Vector3(20, 0, 20), Vector3(72, 0, 10)]:
        var screen := camera.unproject_position(point)
        var pixel := image.get_pixel(roundi(screen.x), roundi(screen.y))
        _check(pixel.g > pixel.r * 1.5 and pixel.g > pixel.b * 1.5,
            label + " renderer cannot see the top of mapped full/clipped land")
    var ocean_screen := camera.unproject_position(Vector3(120, 0, 40))
    var ocean_pixel := image.get_pixel(roundi(ocean_screen.x), roundi(ocean_screen.y))
    _check(ocean_pixel.b > ocean_pixel.g * 1.5,
        label + " renderer obscured an actual water point with imaginary land")

func _run() -> void:
    var directory := "user://terrain_coast_test_%d" % Time.get_ticks_msec()
    var heights_root := directory + "/terrain"
    var coast_root := directory + "/coast"
    DirAccess.make_dir_recursive_absolute(heights_root)
    DirAccess.make_dir_recursive_absolute(coast_root)
    var origin := {"easting": 800000.0, "northing": 650000.0}
    _json(heights_root + "/manifest.json", {"format": 1, "crs": "EPSG:3448", "origin": origin,
        "tile_size": 128.0, "resolution": 3, "sample_spacing_m": 64.0, "max_height": 0.0,
        "tiles": [{"x": 0, "z": 0, "file": "height_0_0.bin"}],
        "overview": {"file": "overview.bin", "origin_x": 0.0, "origin_z": 0.0,
            "width": 5, "depth": 3, "spacing": 64.0}})
    _json(coast_root + "/manifest.json", {"format": 1, "crs": "EPSG:3448", "origin": origin,
        "tile_size": 128.0, "resolution": 3})
    _write(heights_root + "/height_0_0.bin", PackedFloat32Array([0,0,0,0,0,0,0,0,0]).to_byte_array())
    _write(heights_root + "/overview.bin", PackedFloat32Array([0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]).to_byte_array())
    _write(coast_root + "/mask_0_0.bin", PackedByteArray([1,2,0,0]))
    _write(coast_root + "/land_0_0.bin", PackedFloat32Array([64,0,0,64,0,64,100,0,0]).to_byte_array())
    _write(coast_root + "/water_0_0.bin", PackedFloat32Array([128,0,0,40,100,0,0,0,128,0,64,40]).to_byte_array())
    _write(coast_root + "/beach_0_0.bin", PackedByteArray())
    _write(coast_root + "/overview_mask.bin", PackedByteArray([1,2,0,0,0,0,0,0]))
    _write(coast_root + "/overview_land.bin", PackedFloat32Array([64,0,0,64,0,64,100,0,0]).to_byte_array())
    _write(coast_root + "/overview_water.bin", PackedFloat32Array([
        128,0,0,40,100,0,0,0,128,0,64,40,
        128,0,0,40,128,0,128,40,256,0,0,40,
        256,0,0,40,128,0,128,40,256,0,128,40]).to_byte_array())
    var target := Node3D.new()
    target.position = Vector3(20,2,20)
    get_root().add_child(target)
    var terrain := Terrain.new()
    terrain.data_root = heights_root
    terrain.coast_root = coast_root
    terrain.target = target
    terrain.visuals = Visuals.new()
    terrain.load_radius = 0
    get_root().add_child(terrain)
    for frame in range(300):
        if terrain._loaded.has("0:0") and terrain._far_sectors.has("1:0"):
            break
        await process_frame
    _check(terrain._loaded.has("0:0"), "Registered terrain fixture never streamed")
    _check(terrain._far_sectors.has("0:0") and terrain._far_sectors.has("1:0"), "Far coast sectors never assembled")
    if not terrain._loaded.has("0:0"):
        terrain.free()
        target.free()
        quit(1)
        return
    _check(is_zero_approx(terrain.height_at(20.0,20.0)), "Zero-height mapped land disappeared")
    _check(is_zero_approx(terrain.height_at(72.0,10.0)), "Partial coastal land height unavailable")
    _check(is_nan(terrain.height_at(120.0,40.0)), "Water point exposed imaginary terrain height")
    _check(is_nan(terrain.height_at(20.0,80.0)), "Water cell exposed imaginary terrain height")
    var near_root: Node3D = terrain._loaded["0:0"]
    var land: MeshInstance3D = near_root.get_node("RegisteredLand")
    _check(land.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX].size() == 9, "Render faces include water grid cells")
    _check(land.mesh.surface_get_material(0) is ShaderMaterial, "Canonical terrain texture material not used")
    _check_clockwise(land.mesh, "Near full-grid/clipped coast")
    _check(near_root.has_node("RegisteredOcean"), "Clipped tile water was not instantiated")
    if terrain._far_sectors.has("0:0") and terrain._far_sectors.has("1:0"):
        _check(not terrain._far_sectors["0:0"].visible, "Far sector duplicates loaded near terrain")
        _check(terrain._far_sectors["1:0"].visible, "Unloaded ocean sector disappeared")
        var far_land := terrain._far_sectors["0:0"].get_node("OverviewLand") as MeshInstance3D
        _check_clockwise(far_land.mesh, "Far full-grid/clipped coast")
    await _render_land(terrain, near_root, "near")
    await physics_frame
    var space := target.get_world_3d().direct_space_state
    var ray := PhysicsRayQueryParameters3D.create(Vector3(20,2,20),Vector3(20,-2,20),1)
    var contact := space.intersect_ray(ray)
    _check(not contact.is_empty(), "Mapped sea-level land has no collision")
    if not contact.is_empty():
        _check(contact.normal.y > 0.99, "A downward ray receives an inverted terrain contact normal")
    ray.from = Vector3(20,2,80)
    ray.to = Vector3(20,-2,80)
    _check(space.intersect_ray(ray).is_empty(), "Collision still covers unmapped ocean")
    var water: MeshInstance3D = near_root.get_node("RegisteredOcean")
    var old_water_position := water.global_position
    var old_far_position: Vector3 = terrain._far_sectors["1:0"].global_position
    var shift: Vector3 = terrain.coordinates.rebase(1000.0,-400.0,30.0)
    target.position += shift
    terrain.rebase_by(shift)
    _check(water.global_position.is_equal_approx(old_water_position + shift), "Coast water rebased twice or moved incorrectly")
    _check(terrain._far_sectors["1:0"].global_position.is_equal_approx(old_far_position + shift), "Far ocean rebased incorrectly")
    _check(is_zero_approx(terrain.height_at(20.0,20.0)), "Origin rebase changed canonical coastal height")
    terrain.set_process(false)
    near_root.queue_free()
    terrain._loaded.erase("0:0")
    terrain.tile_removed.emit(Vector2i.ZERO)
    _check(terrain._far_sectors["0:0"].visible, "Far sector failed to return after near tile unload")
    _check(is_nan(terrain.height_at(20.0,20.0)), "Unloaded collision data stayed resident")
    # Return to the original render origin to compare the distant sector at the
    # same canonical points once the near tile has actually left the scene.
    var restore: Vector3 = terrain.coordinates.rebase(0.0, 0.0, 0.0)
    terrain.rebase_by(restore)
    await process_frame
    await _render_land(terrain, terrain._far_sectors["0:0"], "far")
    terrain.free()
    target.free()
    for root in [heights_root,coast_root]:
        var access := DirAccess.open(root)
        for filename in access.get_files():
            DirAccess.remove_absolute(root + "/" + filename)
        DirAccess.remove_absolute(root)
    DirAccess.remove_absolute(directory)
    if failures == 0:
        print("YARDMAN_TERRAIN_COAST_TEST PASS sea_level_land=1 ocean_collision=0 far_overlap=0 rebase=1 unload=1 clockwise_normals=1 ground_contact_normal=1 actual_gl=" + str(DisplayServer.get_name() != "headless"))
    quit(0 if failures == 0 else 1)
