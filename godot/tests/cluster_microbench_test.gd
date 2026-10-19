extends SceneTree

# RDX-004 frozen evaluator. The candidate may reorder render indices/instances,
# but it may not lose geometry, shrink conservative bounds, or change the
# Compatibility production path. Efficiency gates are spatial-work ratios only;
# hosted-runner wall-clock time is deliberately excluded from grading.
const ClusterPolicy = preload("res://scripts/render_cluster_policy.gd")
const BuildingStreamer = preload("res://scripts/building_streamer.gd")
const TRIANGLE_LIMIT := 32
const POINT_LIMIT := 16
const CLUSTER_METADATA_BYTES := 32.0
const BUILDING_VISIBILITY_FRACTION_MAX := 0.45
const VEGETATION_VISIBILITY_FRACTION_MAX := 0.45
const METADATA_FRACTION_MAX := 0.08

var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("RDX_CLUSTER_MICROBENCH: " + message)

func _run() -> void:
    var building := _representative_building_geometry()
    var vertices: PackedVector3Array = building.vertices
    var indices: PackedInt32Array = building.indices
    _check(vertices.size() > 1000 and indices.size() > 1000, "representative building geometry is too small")
    _check(indices.size() % 3 == 0, "production building fixture is not triangles")

    var clustered: Dictionary = ClusterPolicy.cluster_indexed_triangles(vertices, indices, TRIANGLE_LIMIT)
    var clustered_again: Dictionary = ClusterPolicy.cluster_indexed_triangles(vertices, indices, TRIANGLE_LIMIT)
    _check(not clustered.has("error"), "building cluster candidate rejected valid production geometry: %s" % str(clustered.get("error", "")))
    _check(var_to_str(clustered) == var_to_str(clustered_again), "building clustering is not deterministic")
    var building_metrics := _validate_triangle_clusters(vertices, indices, clustered)

    var points := _representative_vegetation_points()
    var point_clusters: Dictionary = ClusterPolicy.cluster_points(points, POINT_LIMIT)
    var point_clusters_again: Dictionary = ClusterPolicy.cluster_points(points, POINT_LIMIT)
    _check(not point_clusters.has("error"), "vegetation cluster candidate rejected valid points: %s" % str(point_clusters.get("error", "")))
    _check(var_to_str(point_clusters) == var_to_str(point_clusters_again), "vegetation clustering is not deterministic")
    var vegetation_metrics := _validate_point_clusters(points, point_clusters)

    var invalid_indices := PackedInt32Array([0, 1, vertices.size() + 7])
    var invalid := ClusterPolicy.cluster_indexed_triangles(vertices, invalid_indices, TRIANGLE_LIMIT)
    _check(invalid.has("error"), "out-of-range triangle index was accepted")
    var malformed := ClusterPolicy.cluster_indexed_triangles(vertices, PackedInt32Array([0, 1]), TRIANGLE_LIMIT)
    _check(malformed.has("error"), "non-triangle index payload was accepted")
    var bad_points := PackedVector3Array([Vector3.ZERO, Vector3(NAN, 0.0, 0.0)])
    var invalid_points := ClusterPolicy.cluster_points(bad_points, POINT_LIMIT)
    _check(invalid_points.has("error"), "non-finite vegetation point was accepted")

    var status := "PASS" if failures == 0 else "FAIL"
    print("YARDMAN_RDX_CLUSTER_MICROBENCH result=%s building_triangles=%d building_clusters=%d building_visible_fraction=%.4f building_metadata_fraction=%.4f vegetation_points=%d vegetation_clusters=%d vegetation_visible_fraction=%.4f vegetation_metadata_fraction=%.4f false_culls=%d" % [
        status,
        indices.size() / 3,
        int(building_metrics.cluster_count),
        float(building_metrics.visible_fraction),
        float(building_metrics.metadata_fraction),
        points.size(),
        int(vegetation_metrics.cluster_count),
        float(vegetation_metrics.visible_fraction),
        float(vegetation_metrics.metadata_fraction),
        int(building_metrics.false_culls) + int(vegetation_metrics.false_culls),
    ])
    quit(0 if failures == 0 else 1)

func _empty_build_state() -> Dictionary:
    return {
        "wall_vertices": PackedVector3Array(),
        "wall_normals": PackedVector3Array(),
        "wall_uvs": PackedVector2Array(),
        "wall_colors": PackedColorArray(),
        "wall_uv2s": PackedVector2Array(),
        "facades": [],
        "wall_indices": PackedInt32Array(),
        "roof_vertices": PackedVector3Array(),
        "roof_normals": PackedVector3Array(),
        "roof_uvs": PackedVector2Array(),
        "roof_colors": PackedColorArray(),
        "roof_indices": PackedInt32Array(),
    }

func _building_record(identifier: String, center: Vector2, size: Vector2, roof_y: float) -> Array:
    var hx := size.x * 0.5
    var hz := size.y * 0.5
    var ring := [
        [center.x - hx, 0.0, center.y - hz],
        [center.x + hx, 0.0, center.y - hz],
        [center.x + hx, 0.0, center.y + hz],
        [center.x - hx, 0.0, center.y + hz],
    ]
    var roof := [
        [center.x - hx, center.y - hz],
        [center.x + hx, center.y - hz],
        [center.x + hx, center.y + hz],
        [center.x - hx, center.y + hz],
    ]
    return [identifier, roof_y, 0, 0, roof_y, [ring], roof, [0, 1, 2, 0, 2, 3]]

func _representative_building_geometry() -> Dictionary:
    var streamer = BuildingStreamer.new()
    streamer.reference_facades_enabled = false
    streamer._build = _empty_build_state()
    for z in range(8):
        for x in range(8):
            var center := Vector2(-98.0 + float(x) * 28.0, -98.0 + float(z) * 28.0)
            var width := 8.0 + float((x * 7 + z * 3) % 6)
            var depth := 8.0 + float((x * 5 + z * 11) % 7)
            var roof_y := 5.5 + float((x * 13 + z * 17) % 9)
            var record := _building_record("rdx_%d_%d" % [x, z], center, Vector2(width, depth), roof_y)
            _check(streamer._append_building(record), "production building generator rejected representative record")
    var wall_vertices: PackedVector3Array = streamer._build.wall_vertices
    var wall_indices: PackedInt32Array = streamer._build.wall_indices
    var roof_vertices: PackedVector3Array = streamer._build.roof_vertices
    var roof_indices: PackedInt32Array = streamer._build.roof_indices
    var vertices := PackedVector3Array()
    vertices.append_array(wall_vertices)
    vertices.append_array(roof_vertices)
    var indices := PackedInt32Array()
    indices.append_array(wall_indices)
    var roof_offset := wall_vertices.size()
    for index in roof_indices:
        indices.append(roof_offset + index)
    streamer.free()
    return {"vertices": vertices, "indices": indices}

func _representative_vegetation_points() -> PackedVector3Array:
    var points := PackedVector3Array()
    for z in range(16):
        for x in range(16):
            var jitter_x := float((x * 37 + z * 19) % 9) * 0.31
            var jitter_z := float((x * 23 + z * 43) % 11) * 0.27
            var y := 2.0 + float((x * 17 + z * 29) % 13) * 1.4
            points.append(Vector3(-105.0 + float(x) * 14.0 + jitter_x, y, -105.0 + float(z) * 14.0 + jitter_z))
    return points

func _query_volumes() -> Array[AABB]:
    var queries: Array[AABB] = []
    for z in [-90.0, -30.0, 30.0, 90.0]:
        for x in [-90.0, -30.0, 30.0, 90.0]:
            queries.append(AABB(Vector3(x - 35.0, -2.0, z - 35.0), Vector3(70.0, 28.0, 70.0)))
    return queries

func _triangle_key(indices: PackedInt32Array, first: int) -> String:
    return "%d,%d,%d" % [indices[first], indices[first + 1], indices[first + 2]]

func _triangle_multiset(indices: PackedInt32Array) -> Dictionary:
    var result: Dictionary = {}
    for first in range(0, indices.size(), 3):
        var key := _triangle_key(indices, first)
        result[key] = int(result.get(key, 0)) + 1
    return result

func _triangle_bounds(vertices: PackedVector3Array, indices: PackedInt32Array, first: int) -> AABB:
    var a := vertices[indices[first]]
    var b := vertices[indices[first + 1]]
    var c := vertices[indices[first + 2]]
    var minimum := Vector3(minf(a.x, minf(b.x, c.x)), minf(a.y, minf(b.y, c.y)), minf(a.z, minf(b.z, c.z)))
    var maximum := Vector3(maxf(a.x, maxf(b.x, c.x)), maxf(a.y, maxf(b.y, c.y)), maxf(a.z, maxf(b.z, c.z)))
    return AABB(minimum, maximum - minimum + Vector3.ONE * 0.0001)

func _bounds_contains(bounds: AABB, point: Vector3, epsilon := 0.0005) -> bool:
    var end := bounds.end
    return point.x >= bounds.position.x - epsilon and point.y >= bounds.position.y - epsilon and point.z >= bounds.position.z - epsilon \
        and point.x <= end.x + epsilon and point.y <= end.y + epsilon and point.z <= end.z + epsilon

func _validate_triangle_clusters(vertices: PackedVector3Array, source_indices: PackedInt32Array, candidate: Dictionary) -> Dictionary:
    var reordered: PackedInt32Array = candidate.get("indices", PackedInt32Array())
    var clusters: Array = candidate.get("clusters", [])
    _check(reordered.size() == source_indices.size(), "clustered building index count changed")
    _check(_triangle_multiset(reordered) == _triangle_multiset(source_indices), "clustered building triangles changed, duplicated, or disappeared")
    _check(not clusters.is_empty(), "building clustering produced no clusters")

    var next_first := 0
    for cluster: Dictionary in clusters:
        var first := int(cluster.get("first_index", -1))
        var count := int(cluster.get("index_count", -1))
        var bounds: AABB = cluster.get("bounds", AABB())
        _check(first == next_first, "building cluster ranges are not contiguous")
        _check(count > 0 and count % 3 == 0 and count <= TRIANGLE_LIMIT * 3, "building cluster exceeds triangle budget")
        _check(bounds.position.is_finite() and bounds.size.is_finite(), "building cluster bounds are non-finite")
        for offset in range(first, mini(first + count, reordered.size())):
            var vertex_index := reordered[offset]
            _check(vertex_index >= 0 and vertex_index < vertices.size(), "clustered building index is out of range")
            if vertex_index >= 0 and vertex_index < vertices.size():
                _check(_bounds_contains(bounds, vertices[vertex_index]), "building cluster bound shrank inside referenced geometry")
        next_first += count
    _check(next_first == reordered.size(), "building cluster ranges do not cover the index buffer")

    var false_culls := 0
    var visible_sum := 0
    var reference_sum := 0
    var queries := _query_volumes()
    for query: AABB in queries:
        var visible_keys: Dictionary = {}
        var candidate_visible := 0
        for cluster: Dictionary in clusters:
            var bounds: AABB = cluster.bounds
            if not bounds.intersects(query):
                continue
            var first := int(cluster.first_index)
            var count := int(cluster.index_count)
            candidate_visible += count / 3
            for offset in range(first, first + count, 3):
                visible_keys[_triangle_key(reordered, offset)] = true
        var reference_visible := 0
        for first in range(0, source_indices.size(), 3):
            if _triangle_bounds(vertices, source_indices, first).intersects(query):
                reference_visible += 1
                if not visible_keys.has(_triangle_key(source_indices, first)):
                    false_culls += 1
        _check(candidate_visible >= reference_visible, "candidate building work is below independent visible-triangle reference")
        visible_sum += candidate_visible
        reference_sum += reference_visible
    _check(false_culls == 0, "building cluster bounds caused false culling")
    var baseline_work := float(source_indices.size() / 3 * queries.size())
    var visible_fraction := float(visible_sum) / maxf(baseline_work, 1.0)
    var metadata_fraction := float(clusters.size()) * CLUSTER_METADATA_BYTES / maxf(float(source_indices.size() * 4), 1.0)
    _check(visible_fraction <= BUILDING_VISIBILITY_FRACTION_MAX, "building clusters do not reduce coarse-cell submitted geometry enough")
    _check(metadata_fraction <= METADATA_FRACTION_MAX, "building cluster metadata exceeds budget")
    _check(reference_sum > 0, "building visibility oracle observed no geometry")
    return {"cluster_count": clusters.size(), "visible_fraction": visible_fraction, "metadata_fraction": metadata_fraction, "false_culls": false_culls}

func _validate_point_clusters(points: PackedVector3Array, candidate: Dictionary) -> Dictionary:
    var clusters: Array = candidate.get("clusters", [])
    _check(not clusters.is_empty(), "vegetation clustering produced no clusters")
    var ownership: Dictionary = {}
    for cluster: Dictionary in clusters:
        var members: PackedInt32Array = cluster.get("members", PackedInt32Array())
        var bounds: AABB = cluster.get("bounds", AABB())
        _check(members.size() > 0 and members.size() <= POINT_LIMIT, "vegetation cluster exceeds point budget")
        _check(bounds.position.is_finite() and bounds.size.is_finite(), "vegetation cluster bounds are non-finite")
        for member in members:
            _check(member >= 0 and member < points.size(), "vegetation cluster member is out of range")
            _check(not ownership.has(member), "vegetation instance appears in multiple clusters")
            ownership[member] = true
            if member >= 0 and member < points.size():
                _check(_bounds_contains(bounds, points[member]), "vegetation cluster bound shrank inside member position")
    _check(ownership.size() == points.size(), "vegetation clustering lost instances")

    var false_culls := 0
    var visible_sum := 0
    var reference_sum := 0
    var queries := _query_volumes()
    for query: AABB in queries:
        var visible_members: Dictionary = {}
        for cluster: Dictionary in clusters:
            var bounds: AABB = cluster.bounds
            if not bounds.intersects(query):
                continue
            var members: PackedInt32Array = cluster.members
            visible_sum += members.size()
            for member in members:
                visible_members[member] = true
        for index in range(points.size()):
            if query.has_point(points[index]):
                reference_sum += 1
                if not visible_members.has(index):
                    false_culls += 1
    _check(false_culls == 0, "vegetation cluster bounds caused false culling")
    var baseline_work := float(points.size() * queries.size())
    var visible_fraction := float(visible_sum) / maxf(baseline_work, 1.0)
    var metadata_fraction := float(clusters.size()) * CLUSTER_METADATA_BYTES / maxf(float(points.size() * 48), 1.0)
    _check(visible_fraction <= VEGETATION_VISIBILITY_FRACTION_MAX, "vegetation clusters do not reduce coarse-cell submitted instances enough")
    _check(metadata_fraction <= METADATA_FRACTION_MAX, "vegetation cluster metadata exceeds budget")
    _check(reference_sum > 0, "vegetation visibility oracle observed no points")
    return {"cluster_count": clusters.size(), "visible_fraction": visible_fraction, "metadata_fraction": metadata_fraction, "false_culls": false_culls}
