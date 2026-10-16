extends SceneTree

const CorridorRuntime = preload("res://scripts/road_corridor_terrain_runtime.gd")
var failures := 0

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
    _require(int(rebuilt.micro_triangles) == 326, "8m grid plus actual ribbon boundaries changed unexpectedly")
    var arrays: Array = rebuilt.arrays
    var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
    var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
    _require(indices.size() / 3 == 330, "replacement triangle count is not deterministic")
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
    # A full-tile diagonal used to refine its whole bounding rectangle (4096
    # cells, >524k replacement triangles) rather than the actual road corridor.
    var national_mask := PackedByteArray()
    national_mask.resize(64 * 64)
    national_mask.fill(1)
    var diagonal := road.duplicate(true)
    diagonal[0] = 0.0
    diagonal[1] = 0.0
    diagonal[2] = 4096.0
    diagonal[3] = 4096.0
    diagonal[11] = [[-3.0, 10.0, 3.0], [3.0, 10.0, -3.0], [4099.0, 10.0, 4093.0], [4093.0, 10.0, 4099.0]]
    var diagonal_plan := runtime.refinement_plan([diagonal], Vector2i.ZERO, 4096.0, 64.0, 65, national_mask)
    _require(diagonal_plan.cells.size() < 300, "diagonal road still refines its bounding rectangle")
    _require(diagonal_plan.cells.has("0:0") and diagonal_plan.cells.has("63:63") and diagonal_plan.cells.has("32:32"),
        "narrow-phase selection lost diagonal road cells")
    _require(not diagonal_plan.cells.has("0:63") and not diagonal_plan.cells.has("63:0"),
        "distant terrain selected by diagonal bounding box")
    var national_heights := PackedFloat32Array()
    national_heights.resize(65 * 65)
    national_heights.fill(30.0)
    var national_rebuild := runtime.rebuild_land_arrays(_source_mesh(65), national_heights,
        diagonal_plan.cells, Vector2i.ZERO, 4096.0, 64.0, 65, 8.0)
    _require(bool(national_rebuild.ok), "sparse national-scale tile rebuild failed")
    _require(int(national_rebuild.removed_triangles) == diagonal_plan.cells.size() * 2,
        "sparse selection removed terrain outside selected road cells")
    _require(int(national_rebuild.micro_triangles) >= diagonal_plan.cells.size() * 128 and int(national_rebuild.micro_triangles) < diagonal_plan.cells.size() * 220,
        "ribbon splits exceeded the bounded selective refinement budget")
    var national_indices: PackedInt32Array = national_rebuild.arrays[Mesh.ARRAY_INDEX]
    _require(national_indices.size() / 3 == 8192 - diagonal_plan.cells.size() * 2 + int(national_rebuild.micro_triangles),
        "sparse rebuild lost untouched national terrain triangles")
    var shifted := diagonal.duplicate(true)
    for index in [0, 2]:
        shifted[index] += 4096.0
    for vertex in shifted[11]:
        vertex[0] += 4096.0
    var shifted_plan := runtime.refinement_plan([shifted], Vector2i(1, 0), 4096.0, 64.0, 65, national_mask)
    _require(shifted_plan.cells.keys() == diagonal_plan.cells.keys(), "corridor selection changes under registered tile translation")
    var off_tile := runtime.refinement_plan([shifted], Vector2i(-2, -2), 4096.0, 64.0, 65, national_mask)
    _require(off_tile.cells.is_empty(), "out-of-tile corridor was clamped onto unrelated tile borders")
    _require(runtime._corridor_touches_cell(Vector2(-10.0, 32.0), Vector2(80.0, 32.0), 1.0, Rect2(0, 0, 64, 64)),
        "segment crossing cell interior was missed")
    _require(runtime._corridor_touches_cell(Vector2(-2.0, -2.0), Vector2(-1.0, -1.0), 1.5, Rect2(0, 0, 64, 64)),
        "rounded corridor endpoint near cell corner was missed")
    _require(not runtime._corridor_touches_cell(Vector2(-2.0, -2.0), Vector2(-1.0, -1.0), 1.0, Rect2(0, 0, 64, 64)),
        "square-corner expansion fabricated diagonal corridor coverage")

    # Measure the surface that the renderer/collision actually interpolates,
    # including both road edges and ends, rather than only grid vertex samples.
    var max_under_deck := -INF
    for x in range(0, 65, 2):
        for z in range(28, 37):
            max_under_deck = maxf(max_under_deck, _mesh_height(arrays, Vector2(x, z)))
    _require(max_under_deck <= 9.8801, "interpolated bank triangles penetrate the road ribbon")
    _require(absf(_mesh_area(arrays) - 128.0 * 128.0) < 0.01, "ribbon partitions created holes or overlapping terrain")
    _require(absf(_mesh_height(arrays, Vector2(32, 63)) - 30.0) < 0.001,
        "ribbon splits altered terrain outside the excavation margin")
    var repeated := runtime.rebuild_land_arrays(source, heights, cells, Vector2i.ZERO, 128.0, 64.0, 3, 8.0)
    _require(repeated.arrays[Mesh.ARRAY_VERTEX] == vertices and repeated.arrays[Mesh.ARRAY_INDEX] == indices,
        "identical ribbon inputs produced nondeterministic terrain geometry")
    _require(_mesh_height(arrays, Vector2(32, 27)) < 30.0 and _mesh_height(arrays, Vector2(32, 0)) == 30.0,
        "roadside cut transition was lost")
    var graded := road.duplicate(true)
    graded[0] = 8.0
    graded[1] = 8.0
    graded[2] = 120.0
    graded[3] = 120.0
    graded[10] = 14.0
    var normal := Vector2(-1.0, 1.0).normalized()
    var start := Vector2(8, 8)
    var end := Vector2(120, 120)
    graded[11] = []
    for point in [start + normal * 4.0, start - normal * 4.0, end - normal * 4.0, end + normal * 4.0]:
        var t := clampf((point - start).dot(end - start) / start.distance_squared_to(end), 0.0, 1.0)
        graded[11].append([point.x, lerpf(10.0, 14.0, t), point.y])
    var graded_plan := runtime.refinement_plan([graded], Vector2i.ZERO, 128.0, 64.0, 3, mask)
    var graded_rebuild := runtime.rebuild_land_arrays(source, heights, graded_plan.cells, Vector2i.ZERO, 128.0, 64.0, 3, 8.0)
    var graded_max_error := -INF
    for index in range(17):
        var t := float(index) / 16.0
        for lateral in [-4.0, -2.0, 0.0, 2.0, 4.0]:
            var y := _mesh_height(graded_rebuild.arrays, start.lerp(end, t) + normal * lateral)
            _require(is_finite(y), "ribbon split left a hole beside a graded diagonal road")
            graded_max_error = maxf(graded_max_error, y - (lerpf(10.0, 14.0, t) - 0.12))
    _require(graded_max_error < 0.001, "diagonal road grade plane has interpolated terrain intrusion")
    _require(absf(_mesh_area(graded_rebuild.arrays) - 128.0 * 128.0) < 0.02,
        "diagonal ribbon partitions lost or overlapped terrain")
    var low_heights := heights.duplicate()
    low_heights.fill(5.0)
    var fill_rebuild := runtime.rebuild_land_arrays(source, low_heights, cells, Vector2i.ZERO, 128.0, 64.0, 3, 8.0)
    _require(absf(_mesh_height(fill_rebuild.arrays, Vector2(32, 32)) - 5.0) < 0.001,
        "ribbon boundary constraints raised fill terrain")
    # A refinement request must survive a transient readiness miss. Streamer
    # signals for roads, terrain, coast and height payloads are not guaranteed
    # to arrive in the same frame.
    var pending_tile := Vector2i(7, 9)
    runtime.set("_connected", true)
    runtime.call("_queue_refine", pending_tile)
    runtime.call("_process", 0.05)
    var pending_after: Dictionary = runtime.get("_pending_tiles")
    _require(pending_after.has(pending_tile), "transiently unavailable corridor refinement was dropped")

    print("BOUNDARY_METRICS micro=%d national_micro=%d under_deck=%.6f graded_error=%.6f" % [
        rebuilt.micro_triangles, national_rebuild.micro_triangles, max_under_deck, graded_max_error])
    runtime.free()
    if failures > 0:
        quit(2)
        return
    print("YARDMAN_ROAD_CORRIDOR_TERRAIN_TEST PASS cells=%d removed=%d micro=%d diagonal_cells=%d avoided_cells=%d" % [
        cells.size(), int(rebuilt.removed_triangles), int(rebuilt.micro_triangles), diagonal_plan.cells.size(), 4096 - diagonal_plan.cells.size()])
    quit(0)

func _source_mesh(resolution: int = 3) -> ArrayMesh:
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var colors := PackedColorArray()
    for z in range(resolution):
        for x in range(resolution):
            vertices.append(Vector3(float(x) * 64.0, 30.0, float(z) * 64.0))
            normals.append(Vector3.UP)
            colors.append(Color(0.2, 0.4, 0.2, 1.0))
    var indices := PackedInt32Array()
    for z in range(resolution - 1):
        for x in range(resolution - 1):
            var a := z * resolution + x
            var b := a + 1
            var c := a + resolution
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
    failures += 1
    push_error("YARDMAN_ROAD_CORRIDOR_TERRAIN_TEST FAIL: " + message)

func _mesh_height(arrays: Array, point: Vector2) -> float:
    var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
    var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
    var result := -INF
    for cursor in range(0, indices.size(), 3):
        var a := vertices[indices[cursor]]
        var b := vertices[indices[cursor + 1]]
        var c := vertices[indices[cursor + 2]]
        var ab := Vector2(b.x - a.x, b.z - a.z)
        var ac := Vector2(c.x - a.x, c.z - a.z)
        var ap := point - Vector2(a.x, a.z)
        var denominator := ab.cross(ac)
        if absf(denominator) < 0.000001:
            continue
        var u := ap.cross(ac) / denominator
        var v := ab.cross(ap) / denominator
        if u >= -0.000001 and v >= -0.000001 and u + v <= 1.000001:
            result = maxf(result, a.y + (b.y - a.y) * u + (c.y - a.y) * v)
    return result

func _mesh_area(arrays: Array) -> float:
    var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
    var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
    var result := 0.0
    for cursor in range(0, indices.size(), 3):
        var a := vertices[indices[cursor]]
        var b := vertices[indices[cursor + 1]]
        var c := vertices[indices[cursor + 2]]
        result += absf(Vector2(b.x - a.x, b.z - a.z).cross(Vector2(c.x - a.x, c.z - a.z))) * 0.5
    return result
