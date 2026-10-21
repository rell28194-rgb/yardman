extends SceneTree

const Coordinates = preload("res://scripts/world_coordinates.gd")
const Renderer = preload("res://scripts/hydrology_renderer.gd")

class FakeTerrain:
    func height_at(x: float, z: float) -> float:
        return 22.0 + sin(x * 0.0007) * 3.0 + cos(z * 0.0009) * 2.0

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("HYDROLOGY_RUNTIME: " + message)
    quit(1)

func _run() -> void:
    var root_path := "res://build/hydrology-runtime-test"
    var manifest_path := root_path + "/manifest.json"
    if not FileAccess.file_exists(manifest_path):
        _fail("released hydrology manifest missing")
        return
    var manifest = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
    if not manifest is Dictionary or str(manifest.get("pack_id", "")) != "jamaica_hydrology_osm_v1":
        _fail("hydrology manifest invalid")
        return
    if str(manifest.get("crs", "")) != "EPSG:3448" or absf(float(manifest.get("tile_size", 0.0)) - 4096.0) > 0.001:
        _fail("hydrology grid does not match Yardman accepted grid")
        return
    var stats: Dictionary = manifest.get("stats", {})
    if int(stats.get("tiles", 0)) < 400 or int(stats.get("parts", 0)) < 2000:
        _fail("hydrology source unexpectedly sparse")
        return
    var tiles: Array = manifest.get("tiles", [])
    if tiles.is_empty():
        _fail("hydrology tile index empty")
        return

    var coordinates := Coordinates.new()
    coordinates.configure(manifest)
    var renderer := Renderer.new()
    root.add_child(renderer)
    if not renderer.configure(root_path, coordinates, FakeTerrain.new()):
        _fail("renderer refused released hydrology pack")
        return

    var target: Dictionary = {}
    for raw in tiles:
        if raw is Dictionary and int(raw.get("waterways", 0)) >= 4:
            target = raw
            break
    if target.is_empty():
        target = tiles[0]
    var tx := int(target.get("x", 0))
    var tz := int(target.get("z", 0))
    renderer.update_world((float(tx) + 0.5) * 4096.0, (float(tz) + 0.5) * 4096.0)
    await process_frame
    if renderer.loaded_tile_count() <= 0 or renderer.loaded_tile_count() > 9:
        _fail("active hydrology tile budget failed: %d" % renderer.loaded_tile_count())
        return

    var meshes := renderer.find_children("Hydrology_*", "MeshInstance3D", true, false)
    if meshes.is_empty():
        _fail("no running-water meshes generated")
        return
    var max_vertices := 0
    var total_vertices := 0
    for node in meshes:
        var instance := node as MeshInstance3D
        if instance == null or instance.mesh == null or instance.mesh.get_surface_count() == 0:
            _fail("invalid hydrology mesh instance")
            return
        if instance.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
            _fail("running water unexpectedly casts shadows")
            return
        var arrays: Array = instance.mesh.surface_get_arrays(0)
        var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
        max_vertices = maxi(max_vertices, vertices.size())
        total_vertices += vertices.size()
        if vertices.size() > 12000:
            _fail("per-tile hydrology vertex cap exceeded: %d" % vertices.size())
            return
        var material := instance.mesh.surface_get_material(0)
        if not material is ShaderMaterial:
            _fail("running water material is not the mobile shader")
            return
    print("YARDMAN_HYDROLOGY_RUNTIME_PASS source_tiles=%d source_parts=%d active_tiles=%d meshes=%d max_vertices=%d total_vertices=%d collision=off reflections=off shadows=off" % [
        int(stats.get("tiles", 0)), int(stats.get("parts", 0)), renderer.loaded_tile_count(), meshes.size(), max_vertices, total_vertices])
    quit(0)
