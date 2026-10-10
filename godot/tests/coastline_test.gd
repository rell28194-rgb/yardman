extends SceneTree

const CoastGeometry = preload("res://scripts/coast_geometry.gd")
const Coastline = preload("res://scripts/coastline.gd")
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

func _run() -> void:
    var directory := "user://coastline_test"
    DirAccess.make_dir_recursive_absolute(directory)
    _write(directory + "/mask_0_0.bin", PackedByteArray([1, 2, 0, 0]))
    _write(directory + "/land_0_0.bin", PackedFloat32Array([64, 0, 0, 64, 0, 64, 100, 0, 0]).to_byte_array())
    _write(directory + "/water_0_0.bin", PackedFloat32Array([128, 0, 0, 40, 100, 0, 0, 0, 128, 0, 64, 40]).to_byte_array())
    _write(directory + "/beach_0_0.bin", PackedByteArray())
    var payload: Dictionary = CoastGeometry.read_tile(directory, Vector2i.ZERO, 3)
    _check(not payload.has("error"), "Coast fixture binary read failed")
    if payload.has("error"):
        quit(1)
        return
    _check(payload.water.size() == 3 and payload.shore_distance.size() == 3, "Water reader lost vertex fields")
    _check(CoastGeometry.contains_land(payload, 20.0, 20.0, 64.0, 3), "Complete sea-level land cell disappeared")
    _check(CoastGeometry.contains_land(payload, 72.0, 10.0, 64.0, 3), "Partial coast land point missing")
    _check(not CoastGeometry.contains_land(payload, 120.0, 40.0, 64.0, 3), "Ocean point was treated as land")
    _check(not CoastGeometry.contains_land(payload, 20.0, 80.0, 64.0, 3), "Water cell was treated as land")
    var coast := Coastline.new()
    var tile_root := Node3D.new()
    get_root().add_child(tile_root)
    get_root().add_child(coast)
    coast.instantiate_tile(Vector2i.ZERO, payload, tile_root, 128.0)
    _check(tile_root.get_child_count() == 1, "Missing or duplicated ocean tile visual")
    var ocean: MeshInstance3D = tile_root.get_child(0)
    _check(ocean.name == "RegisteredOcean", "Wrong coast visual child")
    var arrays := ocean.mesh.surface_get_arrays(0)
    for vertex in arrays[Mesh.ARRAY_VERTEX]:
        _check(is_zero_approx(vertex.y), "Ocean canonical sea elevation is not zero")
    _write(directory + "/mask_0_0.bin", PackedByteArray([1, 3, 0, 0]))
    _check(CoastGeometry.read_tile(directory, Vector2i.ZERO, 3).has("error"), "Invalid mask class was accepted")
    _write(directory + "/mask_0_0.bin", PackedByteArray([1]))
    _check(CoastGeometry.read_tile(directory, Vector2i.ZERO, 3).has("error"), "Truncated mask was accepted")
    _check(CoastGeometry.read_tile(directory, Vector2i(9999, 9999), 3).has("error"), "Missing coastal resources were accepted")
    tile_root.free()
    coast.free()
    for filename in ["mask_0_0.bin", "land_0_0.bin", "water_0_0.bin", "beach_0_0.bin"]:
        DirAccess.remove_absolute(directory + "/" + filename)
    DirAccess.remove_absolute(directory)
    if failures == 0:
        print("YARDMAN_COASTLINE_TEST PASS land_mask=1 clipped_land=1 ocean_extent=1 corrupt_resource=1")
    quit(0 if failures == 0 else 1)
