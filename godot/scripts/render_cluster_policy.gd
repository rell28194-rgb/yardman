extends RefCounted
class_name YardmanRenderClusterPolicy

# Deterministic offline/runtime-neutral spatial clustering for RDX-004.
# This does not change residency, renderer selection, materials, or collision.
# Clusters reorder only triangle index triplets / instance membership so a
# RenderingDevice path can conservatively reject smaller spatial units.
const QUANT_MAX := 65535.0
const BOUNDS_PAD := 0.0001

static func _morton_part(value: int) -> int:
    var result := 0
    var input := value & 0xffff
    for bit in range(16):
        result |= ((input >> bit) & 1) << (bit * 2)
    return result

static func _morton_2d(x: int, z: int) -> int:
    return _morton_part(x) | (_morton_part(z) << 1)

static func _quantize(value: float, minimum: float, maximum: float) -> int:
    var extent := maximum - minimum
    if extent <= 0.000001:
        return 0
    return clampi(roundi((value - minimum) / extent * QUANT_MAX), 0, int(QUANT_MAX))

static func _point_bounds(points: PackedVector3Array, members: PackedInt32Array) -> AABB:
    var minimum := Vector3(INF, INF, INF)
    var maximum := Vector3(-INF, -INF, -INF)
    for member in members:
        var point := points[member]
        minimum.x = minf(minimum.x, point.x)
        minimum.y = minf(minimum.y, point.y)
        minimum.z = minf(minimum.z, point.z)
        maximum.x = maxf(maximum.x, point.x)
        maximum.y = maxf(maximum.y, point.y)
        maximum.z = maxf(maximum.z, point.z)
    return AABB(minimum - Vector3.ONE * BOUNDS_PAD, maximum - minimum + Vector3.ONE * (BOUNDS_PAD * 2.0))

static func _index_bounds(vertices: PackedVector3Array, reordered: PackedInt32Array, first_index: int, index_count: int) -> AABB:
    var minimum := Vector3(INF, INF, INF)
    var maximum := Vector3(-INF, -INF, -INF)
    for offset in range(first_index, first_index + index_count):
        var point := vertices[reordered[offset]]
        minimum.x = minf(minimum.x, point.x)
        minimum.y = minf(minimum.y, point.y)
        minimum.z = minf(minimum.z, point.z)
        maximum.x = maxf(maximum.x, point.x)
        maximum.y = maxf(maximum.y, point.y)
        maximum.z = maxf(maximum.z, point.z)
    return AABB(minimum - Vector3.ONE * BOUNDS_PAD, maximum - minimum + Vector3.ONE * (BOUNDS_PAD * 2.0))

static func cluster_indexed_triangles(vertices: PackedVector3Array, indices: PackedInt32Array, max_triangles: int = 32) -> Dictionary:
    if max_triangles <= 0:
        return {"error": "max_triangles must be positive"}
    if indices.size() % 3 != 0:
        return {"error": "index count is not divisible by three"}
    if indices.is_empty():
        return {"indices": PackedInt32Array(), "clusters": []}
    if vertices.is_empty():
        return {"error": "indexed geometry has no vertices"}
    for vertex in vertices:
        if not vertex.is_finite():
            return {"error": "non-finite vertex"}
    for index in indices:
        if index < 0 or index >= vertices.size():
            return {"error": "triangle index out of range"}

    var minimum := Vector2(INF, INF)
    var maximum := Vector2(-INF, -INF)
    var triangles: Array[Dictionary] = []
    for first in range(0, indices.size(), 3):
        var centroid := (vertices[indices[first]] + vertices[indices[first + 1]] + vertices[indices[first + 2]]) / 3.0
        minimum.x = minf(minimum.x, centroid.x)
        minimum.y = minf(minimum.y, centroid.z)
        maximum.x = maxf(maximum.x, centroid.x)
        maximum.y = maxf(maximum.y, centroid.z)
        triangles.append({"first": first, "centroid": centroid, "ordinal": first / 3})
    for triangle: Dictionary in triangles:
        var centroid: Vector3 = triangle.centroid
        triangle.code = _morton_2d(_quantize(centroid.x, minimum.x, maximum.x), _quantize(centroid.z, minimum.y, maximum.y))
    triangles.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        var ac := int(a.code)
        var bc := int(b.code)
        return int(a.ordinal) < int(b.ordinal) if ac == bc else ac < bc)

    var reordered := PackedInt32Array()
    for triangle: Dictionary in triangles:
        var first := int(triangle.first)
        reordered.append(indices[first])
        reordered.append(indices[first + 1])
        reordered.append(indices[first + 2])

    var clusters: Array[Dictionary] = []
    var max_indices := max_triangles * 3
    var first_index := 0
    while first_index < reordered.size():
        var index_count := mini(max_indices, reordered.size() - first_index)
        # Because the source count is triangles and max_indices is a multiple of
        # three, every non-final and final range remains triangle-aligned.
        var bounds := _index_bounds(vertices, reordered, first_index, index_count)
        clusters.append({"first_index": first_index, "index_count": index_count, "bounds": bounds})
        first_index += index_count
    return {"indices": reordered, "clusters": clusters}

static func cluster_points(points: PackedVector3Array, max_points: int = 16) -> Dictionary:
    if max_points <= 0:
        return {"error": "max_points must be positive"}
    if points.is_empty():
        return {"clusters": []}
    var minimum := Vector2(INF, INF)
    var maximum := Vector2(-INF, -INF)
    for point in points:
        if not point.is_finite():
            return {"error": "non-finite point"}
        minimum.x = minf(minimum.x, point.x)
        minimum.y = minf(minimum.y, point.z)
        maximum.x = maxf(maximum.x, point.x)
        maximum.y = maxf(maximum.y, point.z)

    var ordered: Array[Dictionary] = []
    for index in range(points.size()):
        var point := points[index]
        ordered.append({
            "index": index,
            "code": _morton_2d(_quantize(point.x, minimum.x, maximum.x), _quantize(point.z, minimum.y, maximum.y)),
        })
    ordered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        var ac := int(a.code)
        var bc := int(b.code)
        return int(a.index) < int(b.index) if ac == bc else ac < bc)

    var clusters: Array[Dictionary] = []
    var cursor := 0
    while cursor < ordered.size():
        var count := mini(max_points, ordered.size() - cursor)
        var members := PackedInt32Array()
        for offset in range(count):
            members.append(int(ordered[cursor + offset].index))
        clusters.append({"members": members, "bounds": _point_bounds(points, members)})
        cursor += count
    return {"clusters": clusters}
