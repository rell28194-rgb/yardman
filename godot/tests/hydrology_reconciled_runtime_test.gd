extends SceneTree

const Coordinates = preload("res://scripts/world_coordinates.gd")
const Renderer = preload("res://scripts/hydrology_renderer.gd")

class FailIfSampledTerrain:
    var calls := 0

    func height_at(_x: float, _z: float) -> float:
        calls += 1
        return NAN

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("HYDROLOGY_RECONCILED_RUNTIME: " + message)
    quit(1)

func _run() -> void:
    var root_path := OS.get_environment("YARDMAN_HYDROLOGY_V2_ROOT")
    if root_path.is_empty():
        root_path = "res://build/hydrology-runtime-v2-test"
    var manifest_path := root_path.path_join("manifest.json")
    if not FileAccess.file_exists(manifest_path):
        _fail("runtime-v2 manifest missing")
        return
    var manifest = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
    if not manifest is Dictionary:
        _fail("runtime-v2 manifest invalid")
        return
    if int(manifest.get("format_version", 0)) != 2 or str(manifest.get("pack_id", "")) != "jamaica_hydrology_reconciled_v2":
        _fail("runtime-v2 contract identity mismatch")
        return
    if str(manifest.get("crs", "")) != "EPSG:3448":
        _fail("runtime-v2 CRS mismatch")
        return
    var fields: Array = manifest.get("record_format", [])
    if fields.size() != Renderer.V2_RECORD_FORMAT.size() or fields != Renderer.V2_RECORD_FORMAT:
        _fail("runtime-v2 record format mismatch")
        return
    var tiles: Array = manifest.get("tiles", [])
    if tiles.is_empty():
        _fail("runtime-v2 tile index empty")
        return

    var target: Dictionary = {}
    var target_payload: Dictionary = {}
    for raw_tile in tiles:
        if not raw_tile is Dictionary:
            continue
        var candidate: Dictionary = raw_tile
        var filename := str(candidate.get("file", ""))
        var parsed = JSON.parse_string(FileAccess.get_file_as_string(root_path.path_join(filename)))
        if not parsed is Dictionary:
            continue
        var records: Array = parsed.get("segments", [])
        if records.is_empty():
            continue
        target = candidate
        target_payload = parsed
        for raw_record in records:
            if raw_record is Array and raw_record.size() >= Renderer.V2_RECORD_FORMAT.size() and raw_record[19] is Array and raw_record[19].is_empty():
                target = candidate
                target_payload = parsed
                break
        if not target.is_empty():
            break
    if target.is_empty():
        _fail("runtime-v2 has no usable tile")
        return

    var coordinates := Coordinates.new()
    coordinates.configure(manifest)
    var terrain := FailIfSampledTerrain.new()
    var renderer := Renderer.new()
    root.add_child(renderer)
    if not renderer.configure(root_path, coordinates, terrain):
        _fail("renderer refused runtime-v2 contract")
        return
    if renderer.format_version() != 2 or not renderer.uses_compiled_dem_elevation():
        _fail("renderer did not enter compiled-elevation mode")
        return

    var tx := int(target.get("x", 0))
    var tz := int(target.get("z", 0))
    renderer.update_world((float(tx) + 0.5) * float(manifest.get("tile_size", 4096.0)),
                          (float(tz) + 0.5) * float(manifest.get("tile_size", 4096.0)))
    await process_frame
    if terrain.calls != 0:
        _fail("runtime-v2 sampled terrain instead of using compiled DEM elevations: %d" % terrain.calls)
        return
    if renderer.loaded_tile_count() <= 0 or renderer.loaded_tile_count() > 9:
        _fail("runtime-v2 active tile budget failed: %d" % renderer.loaded_tile_count())
        return
    if renderer.audio_segment_count() > renderer.loaded_tile_count() * 96:
        _fail("runtime-v2 audio geometry budget exceeded")
        return

    var meshes := renderer.find_children("Hydrology_*", "MeshInstance3D", true, false)
    if meshes.is_empty():
        _fail("runtime-v2 generated no water mesh")
        return
    var max_vertices := 0
    for node in meshes:
        var instance := node as MeshInstance3D
        if instance == null or instance.mesh == null or instance.mesh.get_surface_count() == 0:
            _fail("runtime-v2 mesh instance invalid")
            return
        var arrays: Array = instance.mesh.surface_get_arrays(0)
        var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
        max_vertices = maxi(max_vertices, vertices.size())
        if vertices.size() > 12000:
            _fail("runtime-v2 vertex budget exceeded: %d" % vertices.size())
            return
        for vertex in vertices:
            if not is_finite(vertex.x) or not is_finite(vertex.y) or not is_finite(vertex.z):
                _fail("runtime-v2 emitted non-finite geometry")
                return

    # Crossing visibility policy is intentionally non-destructive: approved
    # bridges/fords/road tunnels remain visually continuous; culverts and
    # unresolved crossings clip only the open-water surface around the road.
    var a := Vector3(0.0, 10.0, 0.0)
    var b := Vector3(20.0, 9.0, 0.0)
    var bridge := [{"x": 10.0, "z": 0.0, "status": "approved", "kind": "bridge"}]
    var ford := [{"x": 10.0, "z": 0.0, "status": "approved", "kind": "ford"}]
    var culvert := [{"x": 10.0, "z": 0.0, "status": "approved", "kind": "culvert"}]
    var unresolved := [{"x": 10.0, "z": 0.0, "status": "unresolved", "kind": "unknown"}]
    var bridge_intervals: Array[Vector2] = renderer._visible_intervals(a, b, 3.0, bridge, 0.0, 0.0)
    var ford_intervals: Array[Vector2] = renderer._visible_intervals(a, b, 3.0, ford, 0.0, 0.0)
    var culvert_intervals: Array[Vector2] = renderer._visible_intervals(a, b, 3.0, culvert, 0.0, 0.0)
    var unresolved_intervals: Array[Vector2] = renderer._visible_intervals(a, b, 3.0, unresolved, 0.0, 0.0)
    if bridge_intervals != [Vector2(0.0, 1.0)] or ford_intervals != [Vector2(0.0, 1.0)]:
        _fail("bridge/ford water continuity policy failed")
        return
    if culvert_intervals.size() != 2 or unresolved_intervals.size() != 2:
        _fail("culvert/unresolved road-surface clipping policy failed")
        return

    var stats: Dictionary = manifest.get("stats", {})
    print("YARDMAN_HYDROLOGY_RECONCILED_RUNTIME_PASS segments=%d crossings=%d approved=%d unresolved=%d loaded=%d max_vertices=%d terrain_samples=0" % [
        int(stats.get("segments", 0)), int(stats.get("crossings", 0)), int(stats.get("status_approved", 0)),
        int(stats.get("status_unresolved", 0)), renderer.loaded_tile_count(), max_vertices])
    quit(0)
