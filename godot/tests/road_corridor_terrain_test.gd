extends SceneTree

const CorridorRuntime = preload("res://scripts/road_corridor_terrain_runtime.gd")

func _initialize() -> void:
    var runtime := CorridorRuntime.new()
    var road := [0.0, 32.0, 64.0, 32.0, 8.0, 5, 0, "road", 0, 10.0, 10.0,
        [[0.0, 10.0, 28.0], [0.0, 10.0, 36.0], [64.0, 10.0, 36.0], [64.0, 10.0, 28.0]]]
    var bridge := road.duplicate(true)
    bridge[6] = 2
    bridge[7] = "bridge"
    var mask := PackedByteArray([1, 1, 1, 1])
    var plan := runtime.refinement_plan([road, bridge], Vector2i.ZERO, 128.0, 64.0, 3, mask)
    var cells: Dictionary = plan.cells
    _require(cells.size() == 2, "road corridor should refine two full-land cells")
    _require(int(plan.structural_skips) == 1, "bridge must remain structural authority")
    _require(cells.has("0:0") and cells.has("1:0"), "expected road-row cells were not selected")

    var cut := runtime.carved_height(30.0, 32.0, 32.0, [road])
    _require(absf(cut - 9.88) < 0.0001, "cut terrain was not lowered beneath deck clearance")
    var fill := runtime.carved_height(5.0, 32.0, 32.0, [road])
    _require(absf(fill - 5.0) < 0.0001, "fill terrain must never be raised by excavation pass")
    var far_height := runtime.carved_height(30.0, 32.0, 63.0, [road])
    _require(absf(far_height - 30.0) < 0.0001, "terrain outside excavation margin changed")
    _require(absf(runtime.carved_height(30.0, 32.0, 32.0, [bridge]) - 30.0) < 0.0001,
        "bridge terrain was modified by generic road excavation")

    var source := _source_mesh()
    var heights := PackedFloat32Array([30.0, 30.0, 30.0, 30.0, 30.0, 30.0, 30.0, 30.0, 30.0])
    var rebuilt := runtime.rebuild_land_arrays(source, heights, cells, Vector2i.ZERO, 128.0, 64.0, 3, 8.0)
    _require(bool(rebuilt.ok), "terrain mesh rebuild failed")
    _require(int(rebuilt.removed_triangles) == 4, "wrong number of coarse road-row triangles removed")
    _require(int(rebuilt.micro_triangles) == 256, "8m refinement should generate 128 triangles per 64m cell")
    var arrays: Array = rebuilt.arrays
    var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
    var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
    _require(indices.size() / 3 == 260, "replacement triangle count is not deterministic")
    var found_deck_clearance := false
    for point in vertices:
        if absf(point.x - 32.0) < 0.001 and absf(point.z - 32.0) < 0.001 and absf(point.y - 9.88) < 0.001:
            found_deck_clearance = true
            break
    _require(found_deck_clearance, "refined micro-grid did not carve the road center")

    var coast_mask := PackedByteArray([0, 1, 1, 1])
    var coast_plan := runtime.refinement_plan([road], Vector2i.ZERO, 128.0, 64.0, 3, coast_mask)
    _require(not coast_plan.cells.has("0:0"), "partial coastline cell must stay under sourced coast geometry")
    _require(runtime.refinement_plan([road], Vector2i.ZERO, 128.0, 0.0, 3, mask).cells.is_empty(),
        "invalid spacing must fail closed")

    runtime.free()
    print("YARDMAN_ROAD_CORRIDOR_TERRAIN_TEST PASS cells=%d removed=%d micro=%d" % [
        cells.size(), int(rebuilt.removed_triangles), int(rebuilt.micro_triangles)])
    quit(0)

func _source_mesh() -> ArrayMesh:
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var colors := PackedColorArray()
    for z in range(3):
        for x in range(3):
            vertices.append(Vector3(float(x) * 64.0, 30.0, float(z) * 64.0))
            normals.append(Vector3.UP)
            colors.append(Color(0.2, 0.4, 0.2, 1.0))
    var indices := PackedInt32Array()
    for z in range(2):
        for x in range(2):
            var a := z * 3 + x
            var b := a + 1
            var c := a + 3
            var d := c + 1
            indices.append_array(PackedInt32Array([a, b, c, b, d, c]))
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = normals
    arrays[Mesh.ARRAY_COLOR] = colors
    arrays[Mesh.ARRAY_INDEX] = indices
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    return mesh

func _require(condition: bool, message: String) -> void:
    if condition:
        return
    push_error("YARDMAN_ROAD_CORRIDOR_TERRAIN_TEST FAIL: " + message)
    quit(2)
