extends SceneTree

const Streamer = preload("res://scripts/road_streamer.gd")
const StructureCollision = preload("res://scripts/road_structure_collision.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("ROAD_SURFACE_TEST: " + message)

func _run() -> void:
    # Synthetic road payloads exercise the bounded query index without loading
    # the national data or retaining every road's terrain-triangle polygons.
    var stream = Streamer.new()
    var tile_index: Dictionary = {}
    var segment: Array = [0.0, 64.0, 300.0, 64.0, 6.0, 4, 0, "w1:0:osm:1:osm:2", 0, 0.0, 0.0,
        [[0.0, 0.0, 61.0], [300.0, 0.0, 61.0], [300.0, 0.0, 67.0], [0.0, 0.0, 67.0]],
        [[0.0, -3.0], [300.0, -3.0], [300.0, 3.0], [0.0, 3.0]], 1, 2, 16.7, 0.0, 300.0]
    stream._index_surface_segment(tile_index, segment)
    stream._index_surface_segment(tile_index, segment)
    stream._surface_indices["0:0"] = tile_index
    _check(tile_index.size() == 3, "128 m grid should index only the occupied cells")
    _check(tile_index[Vector2i.ZERO].size() == 1, "Terrain fragments duplicated logical segment in the index")
    var on_road: Dictionary = stream.road_surface_at(140.0, 65.0)
    _check(on_road.found and on_road.surface == "paved", "On-road surface lookup failed")
    _check(absf(float(on_road.distance_m) - 1.0) < 0.001, "Source centreline distance changed")
    _check(absf(float(on_road.speed_limit_mps) - 16.7) < 0.001, "Source speed metadata absent")
    _check(not stream.road_surface_at(140.0, 70.0).found, "Off-road position classified as road")
    var paths: Array[PackedVector2Array] = stream.nearby_paths(140.0, 64.0, 220.0)
    _check(paths.size() == 1 and paths[0].size() == 2, "Nearby map paths must deduplicate all occupied cells")
    stream._surface_indices.erase("0:0")
    _check(not stream.road_surface_at(140.0, 64.0).found, "Unloaded geometry left a stale road surface")
    _check(stream.nearby_paths(140.0, 64.0).is_empty(), "Unloaded geometry left stale radar paths")
    _check(stream.road_surface_at(NAN, 0.0).found == false, "Invalid coordinates must return no surface")

    # Bridges and profiled tunnels are forbidden from relying on the terrain
    # collider; each receives collision from the exact streamed road ribbon.
    var bridge: Array = [0.0, 0.0, 20.0, 0.0, 7.2, 4, 2, "bridge:0:osm:1:osm:2", 0, 12.0, 12.5,
        [[0.0, 12.0, -3.6], [20.0, 12.5, -3.6], [20.0, 12.5, 3.6], [0.0, 12.0, 3.6]],
        [[0.0, -3.6], [20.0, -3.6], [20.0, 3.6], [0.0, 3.6]], 1, 2, 16.7, 0.0, 20.0]
    var tunnel: Array = [40.0, 0.0, 60.0, 0.0, 7.2, 4, 4, "tunnel:0:osm:3:osm:4", 0, 9.0, 8.0,
        [[40.0, 9.0, -3.6], [60.0, 8.0, -3.6], [60.0, 8.0, 3.6], [40.0, 9.0, 3.6]],
        [[0.0, -3.6], [20.0, -3.6], [20.0, 3.6], [0.0, 3.6]], 1, 2, 16.7, 0.0, 20.0]
    var helper = StructureCollision.new()
    helper.roads = stream
    var tile_root := Node3D.new()
    helper._on_tile_content_ready(Vector2i.ZERO, tile_root, [bridge, tunnel])
    var body := tile_root.get_node_or_null("RoadStructureDeckCollision")
    _check(body != null, "Structure tile did not receive an independent deck collider")
    if body != null:
        var collider := body.get_node_or_null("RoadStructureDeckCollisionShape") as CollisionShape3D
        _check(collider != null and collider.shape is ConcavePolygonShape3D,
            "Road structure deck collision shape is missing or wrong type")
        if collider != null and collider.shape is ConcavePolygonShape3D:
            _check((collider.shape as ConcavePolygonShape3D).get_faces().size() == 12,
                "Bridge plus tunnel quads must produce four collision triangles")
    _check(helper.bridge_tiles_built == 1 and helper.bridge_triangles_built == 2,
        "Bridge collision diagnostics did not match generated deck")
    _check(helper.tunnel_tiles_built == 1 and helper.tunnel_triangles_built == 2,
        "Tunnel collision diagnostics did not match generated deck")
    tile_root.free()
    helper.free()
    stream.free()
    print("YARDMAN_ROAD_SURFACE_TEST %s grid=128 dedup=1 unload=1 surface=1 bridge_collision=1 tunnel_collision=1" % ["PASS" if failures == 0 else "FAIL"])
    quit(0 if failures == 0 else 1)