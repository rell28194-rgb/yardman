extends SceneTree

const StreamerScript = preload("res://scripts/road_streamer.gd")
const CoordinatesScript = preload("res://scripts/world_coordinates.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("STREAMING_TEST: " + message)

func _run() -> void:
    var coords = CoordinatesScript.new()
    coords.projected_origin_easting = 700000.123456
    coords.projected_origin_northing = 650000.654321
    coords.rebase(-166000.123456, -40000.654321)
    var point: Vector3 = coords.world_to_local(-166000.120456, -40000.649321, 2256.0)
    var recovered: PackedFloat64Array = coords.local_to_world(point)
    _check(abs(recovered[0] + 166000.120456) < 0.000001, "National X changed under local rebasing")
    _check(abs(recovered[2] + 40000.649321) < 0.000001, "National Z changed under local rebasing")
    _check(recovered[1] == 2256.0, "Elevation must not be compressed")
    _check(coords.tile_for(-0.001, -0.001) == Vector2i(-1, -1), "Negative tile addressing")
    var projected: PackedFloat64Array = coords.world_to_projected(recovered[0], recovered[2], recovered[1])
    var back: PackedFloat64Array = coords.projected_to_world(projected[0], projected[1], projected[2])
    _check(abs(back[0] - recovered[0]) < 0.000001 and abs(back[2] - recovered[2]) < 0.000001, "EPSG/local inverse")
    var container := Node3D.new()
    root.add_child(container)
    var target := Node3D.new()
    container.add_child(target)
    var stream = StreamerScript.new()
    stream.target = target
    stream.load_radius = 1
    container.add_child(stream)
    await _wait_for_tile(stream, Vector2i.ZERO)
    _check(stream.graph.edge_count > 1000, "National topology missing")
    var initial_payload = JSON.parse_string(FileAccess.get_file_as_string("res://data/roads/" + str(stream._tile_files["0:0"])))
    var edge_id: String = str(initial_payload.segments[0][7])
    var edge: Dictionary = stream.graph.get_edge(edge_id)
    _check(not edge.is_empty(), "Mesh reference does not resolve to a logical edge")
    var node: Dictionary = stream.graph.get_node_data(str(edge.get("from", "")))
    _check(node.get("edges", []).has(edge_id), "Graph node adjacency omitted its edge")
    var snapshot := edge.duplicate(true)
    var destination: Dictionary = stream.manifest.parish_anchors.Hanover
    stream.rebase_origin(float(destination.x), float(destination.z))
    target.position = stream.world_to_local(float(destination.x), float(destination.z), 1.0)
    stream._refresh_tiles(true)
    var final_tile: Vector2i = stream.coordinates.tile_for(float(destination.x), float(destination.z))
    await _wait_for_tile(stream, final_tile)
    _check(not stream.is_tile_ready(Vector2i.ZERO), "Distant mesh did not unload")
    stream.graph.clear_cache()
    _check(stream.graph.get_edge(edge_id) == snapshot, "Tile eviction changed logical road topology")
    for parish in ["Portland", "St. Elizabeth", "St. Thomas", "St. James", "Hanover"]:
        var anchor: Dictionary = stream.manifest.parish_anchors[parish]
        stream.rebase_origin(float(anchor.x), float(anchor.z))
        target.position = stream.world_to_local(float(anchor.x), float(anchor.z), 1.0)
        stream._refresh_tiles(true)
        for frame in range(3):
            await process_frame
        _check(stream.inflight_count() <= stream.max_io_jobs, "IO concurrency exceeded its cap")
    await _wait_for_tile(stream, final_tile)
    _check(stream._loaded.size() <= 25, "Residency exceeded load radius plus hysteresis")
    _check(stream.get_child_count() == stream._loaded.size(), "Untracked or stale tile nodes remain")
    _check(stream.graph._cache.size() <= stream.graph.max_cached_partitions, "Graph cache exceeded cap")
    _check(stream._failed.is_empty(), "Tile resources failed to load")
    print("YARDMAN_STREAMING_TEST %s national_edges=%d loaded=%d generation=%d" %
        ["PASS" if failures == 0 else "FAIL", stream.graph.edge_count, stream._loaded.size(), stream.generation])
    container.queue_free()
    await process_frame
    quit(0 if failures == 0 else 1)

func _wait_for_tile(stream, tile: Vector2i) -> void:
    for frame in range(900):
        await process_frame
        if stream.is_tile_ready(tile):
            return
    _check(false, "Timed out waiting for tile " + str(tile))
