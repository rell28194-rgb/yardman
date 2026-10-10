extends SceneTree

const Terrain = preload("res://scripts/terrain_streamer.gd")
const Visuals = preload("res://scripts/world_visuals.gd")
var failures := 0

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
    _check(near_root.has_node("RegisteredOcean"), "Clipped tile water was not instantiated")
    if terrain._far_sectors.has("0:0") and terrain._far_sectors.has("1:0"):
        _check(not terrain._far_sectors["0:0"].visible, "Far sector duplicates loaded near terrain")
        _check(terrain._far_sectors["1:0"].visible, "Unloaded ocean sector disappeared")
    await physics_frame
    var space := target.get_world_3d().direct_space_state
    var ray := PhysicsRayQueryParameters3D.create(Vector3(20,2,20),Vector3(20,-2,20),1)
    _check(not space.intersect_ray(ray).is_empty(), "Mapped sea-level land has no collision")
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
    terrain.free()
    target.free()
    for root in [heights_root,coast_root]:
        var access := DirAccess.open(root)
        for filename in access.get_files():
            DirAccess.remove_absolute(root + "/" + filename)
        DirAccess.remove_absolute(root)
    DirAccess.remove_absolute(directory)
    if failures == 0:
        print("YARDMAN_TERRAIN_COAST_TEST PASS sea_level_land=1 ocean_collision=0 far_overlap=0 rebase=1 unload=1")
    quit(0 if failures == 0 else 1)
