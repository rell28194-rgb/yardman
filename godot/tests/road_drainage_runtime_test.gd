extends SceneTree

const RoadDrainage = preload("res://scripts/road_drainage_runtime.gd")
var failures := 0

class CountingDrainage:
    extends "res://scripts/road_drainage_runtime.gd"
    var reads: Dictionary = {}
    func _read_tile_records(tile: Vector2i) -> Array:
        reads[tile] = int(reads.get(tile, 0)) + 1
        if tile.y == -1:
            return []
        return [{"source_way": "fixture-%d:%d" % [tile.x, tile.y], "kind": "ditch"}]

func _initialize() -> void:
    var runtime := RoadDrainage.new()
    var records := [
        {"source_way": "w10", "kind": "ditch", "start": [10.0, 10.0], "end": [18.0, 10.0], "width_m": 1.2},
        {"source_way": "w20", "kind": "drain", "start": [20.0, 12.0], "end": [24.0, 12.0]},
        {"source_way": "w30", "kind": "culvert", "start": [30.0, 16.0], "end": [34.0, 16.0],
            "width_m": 0.8, "portal_start": true, "portal_end": true, "material": "concrete"},
        {"source_way": "bad", "kind": "stream", "start": [40.0, 10.0], "end": [45.0, 10.0]},
    ]
    var plan: Array[Dictionary] = runtime.placement_plan(records, Vector2i.ZERO, 64.0, 5.0)
    _require(plan.size() == 5, "8m ditch + 4m drain + two culvert portals should produce five plan items")
    var channel_items := 0
    var portal_items := 0
    for item: Dictionary in plan:
        channel_items += int(str(item.kind) == "channel")
        portal_items += int(str(item.kind) == "culvert_portal")
        if str(item.kind) == "channel":
            _require(Vector2(float(item.world_ax), float(item.world_az)).distance_to(
                Vector2(float(item.world_bx), float(item.world_bz))) <= 5.0001,
                "drainage channel span exceeded runtime tessellation bound")
    _require(channel_items == 3, "ditch/drain span count changed")
    _require(portal_items == 2, "explicit culvert endpoint count changed")
    _require(runtime.records_have_channel_near(records, Vector2(14.0, 10.4), 0.25),
        "mapped ditch proximity query missed a nearby source channel")
    _require(not runtime.records_have_channel_near(records, Vector2(14.0, 15.0), 0.25),
        "mapped ditch proximity query reached too far from source geometry")
    _require(not runtime.records_have_channel_near([records[2]], Vector2(32.0, 16.0), 1.0),
        "culvert evidence must not suppress a longitudinal cut-side ditch")

    var sampler := func(x: float, z: float) -> float:
        return 10.0 + x * 0.01 + z * 0.005
    var geometry := runtime.build_geometry(plan, Vector2.ZERO, sampler)
    _require(int(geometry.channel_spans) == 3, "valid drainage channels were dropped")
    _require(int(geometry.culvert_portals) == 2, "valid culvert portals were dropped")
    var vertices: PackedVector3Array = geometry.vertices
    var normals: PackedVector3Array = geometry.normals
    var colors: PackedColorArray = geometry.colors
    var indices: PackedInt32Array = geometry.indices
    _require(vertices.size() == 76, "expected three visible three-quad channels plus two five-quad culvert frames")
    _require(normals.size() == vertices.size() and colors.size() == vertices.size(),
        "drainage vertex attributes are incomplete")
    _require(indices.size() == 114, "drainage quad index count changed")
    for point in vertices:
        _require(is_finite(point.x) and is_finite(point.y) and is_finite(point.z),
            "drainage geometry contains non-finite coordinates")

    var seam_culvert := [{"source_way": "w40", "kind": "culvert", "start": [1.0, 1.0], "end": [5.0, 1.0],
        "portal_start": false, "portal_end": false}]
    _require(runtime.placement_plan(seam_culvert, Vector2i.ZERO, 64.0, 5.0).is_empty(),
        "tile-seam culvert pieces must not invent portal openings")
    _require(runtime.placement_plan(records, Vector2i.ZERO, 0.0, 5.0).is_empty(),
        "invalid tile size must fail closed")
    var invalid_sampler := func(_x: float, _z: float) -> float:
        return NAN
    _require(runtime.build_geometry(plan, Vector2.ZERO, invalid_sampler).vertices.is_empty(),
        "non-finite terrain support must fail closed")

    _test_streamed_record_cache()
    runtime.free()
    if failures > 0:
        quit(2)
        return
    print("YARDMAN_ROAD_DRAINAGE_TEST PASS channel_spans=%d culvert_portals=%d vertices=%d bounded_cache=64 lru=1 unload=1 negative_cache=1" % [
        channel_items, portal_items, vertices.size()])
    quit(0)

func _test_streamed_record_cache() -> void:
    var cache := CountingDrainage.new()
    var hot := Vector2i.ZERO
    var hot_records := cache.records_for_tile(hot)
    for index in range(1, 257):
        _require(cache.records_for_tile(hot) == hot_records, "cached source records changed during traversal")
        cache.records_for_tile(Vector2i(index, 0))
        _require(int(cache.record_cache_snapshot().cached_tiles) <= RoadDrainage.MAX_CACHED_TILES,
            "national traversal retained more than the bounded tile cache")
    _require(int(cache.reads[hot]) == 1, "frequently queried source tile was evicted instead of a cold tile")
    _require(int(cache.record_cache_snapshot().cached_tiles) == RoadDrainage.MAX_CACHED_TILES,
        "LRU cache failed to retain its configured working set")
    _require(int(cache.record_cache_snapshot().evictions) == 193, "cache eviction accounting differs from traversal")
    _require(str(cache.records_for_tile(Vector2i(1, 0))[0].source_way) == "fixture-1:0" and int(cache.reads[Vector2i(1, 0)]) == 2,
        "evicted source tile did not reload unchanged authoritative records")
    var missing := Vector2i(9, -1)
    _require(cache.records_for_tile(missing).is_empty() and cache.records_for_tile(missing).is_empty(),
        "missing source tile invented records")
    _require(int(cache.reads[missing]) == 1, "missing source tile was reread on every proximity query")
    cache._on_terrain_tile_removed(missing)
    _require(cache.records_for_tile(missing).is_empty() and int(cache.reads[missing]) == 2,
        "terrain unload did not release negative cache entry")
    cache._on_terrain_tile_removed(hot)
    _require(cache.records_for_tile(hot) == hot_records and int(cache.reads[hot]) == 2,
        "terrain unload retained stale source metadata")
    cache.free()

func _require(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("YARDMAN_ROAD_DRAINAGE_TEST FAIL: " + message)
    quit(2)
