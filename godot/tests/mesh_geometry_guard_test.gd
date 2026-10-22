extends SceneTree

const MeshGeometryGuard = preload("res://scripts/mesh_geometry_guard.gd")

var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    failures += 1
    push_error("MESH_GEOMETRY_GUARD_TEST: " + message)

func _expect_accept(label: String, vertices: PackedVector3Array, indices: PackedInt32Array,
        max_span_m: float = 8192.0, max_edge_m: float = 6144.0) -> void:
    var result := MeshGeometryGuard.validate(vertices, indices, max_span_m, max_edge_m)
    if not bool(result.get("ok", false)):
        _fail("%s rejected: %s" % [label, str(result)])

func _expect_reject(label: String, expected_reason: String, vertices: PackedVector3Array,
        indices: PackedInt32Array, max_span_m: float = 8192.0, max_edge_m: float = 6144.0) -> void:
    var result := MeshGeometryGuard.validate(vertices, indices, max_span_m, max_edge_m)
    if bool(result.get("ok", false)):
        _fail(label + " unexpectedly accepted")
        return
    if str(result.get("reason", "")) != expected_reason:
        _fail("%s reason=%s expected=%s" % [label, str(result.get("reason", "")), expected_reason])

func _run() -> void:
    var valid_vertices := PackedVector3Array([
        Vector3(0.0, 10.0, 0.0),
        Vector3(64.0, 10.0, 0.0),
        Vector3(0.0, 12.0, 64.0),
    ])
    var valid_indices := PackedInt32Array([0, 1, 2])
    _expect_accept("valid tile triangle", valid_vertices, valid_indices)

    _expect_reject("nonfinite vertex", "non_finite_vertex", PackedVector3Array([
        Vector3(0.0, 0.0, 0.0), Vector3(NAN, 0.0, 1.0), Vector3(1.0, 0.0, 0.0),
    ]), valid_indices)

    _expect_reject("malformed triangle", "malformed_triangle_index_count", valid_vertices,
        PackedInt32Array([0, 1]))
    _expect_reject("bad index", "index_out_of_range", valid_vertices,
        PackedInt32Array([0, 1, 99]))

    _expect_reject("catastrophic span", "local_span_exceeded", PackedVector3Array([
        Vector3(0.0, 0.0, 0.0), Vector3(9000.0, 0.0, 0.0), Vector3(0.0, 0.0, 1.0),
    ]), valid_indices, 8192.0, 12000.0)

    _expect_reject("catastrophic edge", "edge_length_exceeded", PackedVector3Array([
        Vector3(0.0, 0.0, 0.0), Vector3(7000.0, 0.0, 0.0), Vector3(0.0, 0.0, 1.0),
    ]), valid_indices, 8192.0, 6144.0)

    _expect_reject("fully degenerate", "all_triangles_degenerate", PackedVector3Array([
        Vector3(0.0, 0.0, 0.0), Vector3(1.0, 0.0, 0.0), Vector3(2.0, 0.0, 0.0),
    ]), valid_indices)

    if failures > 0:
        quit(1)
        return
    print("YARDMAN_MESH_GEOMETRY_GUARD_TEST PASS finite=1 topology=1 bounds=1 edges=1 degeneracy=1")
    quit(0)
