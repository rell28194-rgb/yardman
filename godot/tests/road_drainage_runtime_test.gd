extends SceneTree

const RoadDrainage = preload("res://scripts/road_drainage_runtime.gd")

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

    var sampler := func(x: float, _z: float) -> float:
        return 10.0 + x * 0.01
    var geometry := runtime.build_geometry(plan, Vector2.ZERO, sampler)
    _require(int(geometry.channel_spans) == 3, "valid drainage channels were dropped")
    _require(int(geometry.culvert_portals) == 2, "valid culvert portals were dropped")
    var vertices: PackedVector3Array = geometry.vertices
    var normals: PackedVector3Array = geometry.normals
    var colors: PackedColorArray = geometry.colors
    var indices: PackedInt32Array = geometry.indices
    _require(vertices.size() == 52, "expected three channel quads plus two five-quad culvert frames")
    _require(normals.size() == vertices.size() and colors.size() == vertices.size(),
        "drainage vertex attributes are incomplete")
    _require(indices.size() == 78, "drainage quad index count changed")
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

    runtime.free()
    print("YARDMAN_ROAD_DRAINAGE_TEST PASS channel_spans=%d culvert_portals=%d vertices=%d" % [
        channel_items, portal_items, vertices.size()])
    quit(0)

func _require(condition: bool, message: String) -> void:
    if condition:
        return
    push_error("YARDMAN_ROAD_DRAINAGE_TEST FAIL: " + message)
    quit(2)
