extends SceneTree

const RetainingWalls = preload("res://scripts/retaining_wall_layer.gd")

func _initialize() -> void:
    var runtime := RetainingWalls.new()
    var records := [
        {
            "source_way": "w100",
            "segment": 0,
            "start": [10.0, 10.0],
            "end": [18.0, 10.0],
            "barrier": "retaining_wall",
            "material": "stone",
            "height_m": 2.5,
        },
        {
            "source_way": "w200",
            "segment": 0,
            "start": [20.0, 10.0],
            "end": [24.0, 10.0],
            "barrier": "retaining_wall",
            "material": "concrete",
        },
        {
            "source_way": "fake",
            "segment": 0,
            "start": [30.0, 10.0],
            "end": [35.0, 10.0],
            "barrier": "wall",
        },
    ]
    var plan: Array[Dictionary] = runtime.placement_plan(records, Vector2i.ZERO, 64.0, 5.0)
    _require(plan.size() == 3, "8m sourced wall should split into two spans plus one 4m fallback span")
    _require(str(plan[0].height_source) == "OSM" and absf(float(plan[0].height_m) - 2.5) < 0.0001,
        "explicit OSM height was not preserved")
    _require(str(plan[2].height_source) == "visual_fallback" and absf(float(plan[2].height_m) - 1.6) < 0.0001,
        "missing OSM height did not use bounded visual fallback")
    for item: Dictionary in plan:
        _require(Vector2(float(item.world_ax), float(item.world_az)).distance_to(
            Vector2(float(item.world_bx), float(item.world_bz))) <= 5.0001,
            "retaining-wall span exceeded runtime tessellation bound")

    var sampler := func(x: float, _z: float) -> float:
        return 10.0 + x * 0.05
    var geometry := runtime.build_geometry(plan, Vector2.ZERO, sampler)
    _require(int(geometry.spans) == 3, "valid retaining-wall spans were dropped")
    _require(int(geometry.explicit_height_spans) == 2, "explicit-height span accounting changed")
    _require(int(geometry.fallback_height_spans) == 1, "fallback-height span accounting changed")
    var vertices: PackedVector3Array = geometry.vertices
    var normals: PackedVector3Array = geometry.normals
    var indices: PackedInt32Array = geometry.indices
    var faces: PackedVector3Array = geometry.collision_faces
    _require(vertices.size() == 72, "each wall prism must retain six four-vertex faces")
    _require(normals.size() == vertices.size(), "wall normals do not match vertex count")
    _require(indices.size() == 108, "each wall prism must retain twelve triangles")
    _require(faces.size() == 108, "wall collision does not match visible triangle coverage")
    for point in vertices:
        _require(is_finite(point.x) and is_finite(point.y) and is_finite(point.z),
            "retaining-wall geometry contains non-finite coordinates")

    _require(runtime.placement_plan(records, Vector2i.ZERO, 0.0, 5.0).is_empty(),
        "invalid tile size must fail closed")
    _require(runtime.placement_plan(records, Vector2i(1, 0), 64.0, 5.0).is_empty(),
        "records must not escape their midpoint tile")
    var invalid_sampler := func(_x: float, _z: float) -> float:
        return NAN
    _require(runtime.build_geometry(plan, Vector2.ZERO, invalid_sampler).vertices.is_empty(),
        "non-finite terrain support must fail closed")

    runtime.free()
    print("YARDMAN_RETAINING_WALL_TEST PASS spans=%d vertices=%d collision_faces=%d" % [
        plan.size(), vertices.size(), faces.size()])
    quit(0)

func _require(condition: bool, message: String) -> void:
    if condition:
        return
    push_error("YARDMAN_RETAINING_WALL_TEST FAIL: " + message)
    quit(2)
