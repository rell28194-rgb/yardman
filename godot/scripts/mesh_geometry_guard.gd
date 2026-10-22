extends RefCounted
class_name MeshGeometryGuard

const DEFAULT_MAX_SPAN_M := 8192.0
const DEFAULT_MAX_EDGE_M := 6144.0
const DEFAULT_MAX_VERTICES := 250000
const DEGENERATE_EPSILON_SQUARED := 0.000000000001

static func validate(vertices: PackedVector3Array, indices: PackedInt32Array,
        max_span_m: float = DEFAULT_MAX_SPAN_M, max_edge_m: float = DEFAULT_MAX_EDGE_M,
        max_vertices: int = DEFAULT_MAX_VERTICES) -> Dictionary:
    if vertices.is_empty():
        return _reject("empty_vertices")
    if indices.is_empty():
        return _reject("empty_indices")
    if indices.size() % 3 != 0:
        return _reject("malformed_triangle_index_count", {"indices": indices.size()})
    if max_vertices > 0 and vertices.size() > max_vertices:
        return _reject("vertex_budget_exceeded", {"vertices": vertices.size(), "limit": max_vertices})
    if not is_finite(max_span_m) or max_span_m <= 0.0 or not is_finite(max_edge_m) or max_edge_m <= 0.0:
        return _reject("invalid_guard_limits")

    var minimum := vertices[0]
    var maximum := vertices[0]
    for vertex_index in range(vertices.size()):
        var vertex := vertices[vertex_index]
        if not _finite_vector(vertex):
            return _reject("non_finite_vertex", {"vertex": vertex_index})
        minimum.x = minf(minimum.x, vertex.x)
        minimum.y = minf(minimum.y, vertex.y)
        minimum.z = minf(minimum.z, vertex.z)
        maximum.x = maxf(maximum.x, vertex.x)
        maximum.y = maxf(maximum.y, vertex.y)
        maximum.z = maxf(maximum.z, vertex.z)

    var span := maximum - minimum
    var largest_span := maxf(span.x, maxf(span.y, span.z))
    if largest_span > max_span_m:
        return _reject("local_span_exceeded", {
            "span": span,
            "largest_span_m": largest_span,
            "limit_m": max_span_m,
        })

    var max_edge := 0.0
    var degenerate_triangles := 0
    var triangle_count := indices.size() / 3
    for cursor in range(0, indices.size(), 3):
        var ia := int(indices[cursor])
        var ib := int(indices[cursor + 1])
        var ic := int(indices[cursor + 2])
        for index in [ia, ib, ic]:
            if index < 0 or index >= vertices.size():
                return _reject("index_out_of_range", {
                    "index": index,
                    "vertices": vertices.size(),
                    "triangle": cursor / 3,
                })
        var a := vertices[ia]
        var b := vertices[ib]
        var c := vertices[ic]
        max_edge = maxf(max_edge, maxf(a.distance_to(b), maxf(b.distance_to(c), c.distance_to(a))))
        if max_edge > max_edge_m:
            return _reject("edge_length_exceeded", {
                "max_edge_m": max_edge,
                "limit_m": max_edge_m,
                "triangle": cursor / 3,
            })
        if (b - a).cross(c - a).length_squared() <= DEGENERATE_EPSILON_SQUARED:
            degenerate_triangles += 1

    if degenerate_triangles == triangle_count:
        return _reject("all_triangles_degenerate", {"triangles": triangle_count})

    return {
        "ok": true,
        "reason": "ok",
        "vertices": vertices.size(),
        "triangles": triangle_count,
        "degenerate": degenerate_triangles,
        "span": span,
        "max_edge_m": max_edge,
    }

static func rejection_message(context: String, result: Dictionary) -> String:
    return "Rejected unsafe streamed geometry %s: %s %s" % [
        context,
        str(result.get("reason", "unknown")),
        str(result.get("details", {})),
    ]

static func _finite_vector(value: Vector3) -> bool:
    return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)

static func _reject(reason: String, details: Dictionary = {}) -> Dictionary:
    return {"ok": false, "reason": reason, "details": details}
