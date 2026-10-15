extends Node

# Jamaica's mountain roads often reveal their engineering through the road trace
# even when widening/apron geometry was never mapped. This runtime detects sharp
# consecutive bends on the authoritative streamed road graph and adds a small,
# collidable outside-turn apron. It never changes navigation topology, bridge or
# tunnel geometry, and deliberately fails closed on narrow tracks.
const FLAG_BRIDGE := 2
const FLAG_TUNNEL := 4
const MIN_ROAD_WIDTH_M := 4.2
const MIN_TURN_DEG := 48.0
const HAIRPIN_TURN_DEG := 105.0
const MIN_SEGMENT_M := 3.0
const MAX_JUNCTION_GAP_M := 1.25
const MIN_WIDEN_M := 0.55
const MAX_WIDEN_M := 2.65
const VISIBILITY_RANGE_M := 1300.0

var _roads: Node
var _connected := false
var _material: StandardMaterial3D
var _segments_by_tile: Dictionary = {}

func _ready() -> void:
    set_process(true)

func _process(_delta: float) -> void:
    if _connected:
        set_process(false)
        return
    var scene := get_tree().current_scene
    if scene == null:
        return
    _roads = scene.get_node_or_null("JamaicaRoadStreamer")
    if _roads == null:
        return
    _roads.tile_content_ready.connect(_on_road_tile)
    _roads.tile_removed.connect(_on_road_tile_removed)
    _connected = true
    set_process(false)

func _on_road_tile(tile: Vector2i, _tile_root: Node3D, segments: Array) -> void:
    _segments_by_tile[tile] = segments.duplicate(false)
    _rebuild_neighborhood(tile)

func _on_road_tile_removed(tile: Vector2i) -> void:
    _segments_by_tile.erase(tile)
    # Neighboring bend ownership may have depended on a segment from this tile.
    # Rebuild loaded neighbors so stale seam aprons cannot survive an unload.
    _rebuild_neighborhood(tile)

func _road_tile_root(tile: Vector2i) -> Node3D:
    if _roads == null:
        return null
    return _roads._loaded.get(_roads._tile_key(tile.x, tile.y)) as Node3D

func _segments_for_neighborhood(tile: Vector2i) -> Array:
    var combined: Array = []
    for z in range(tile.y - 1, tile.y + 2):
        for x in range(tile.x - 1, tile.x + 2):
            var neighbor := Vector2i(x, z)
            if _segments_by_tile.has(neighbor):
                combined.append_array(_segments_by_tile[neighbor])
    return combined

func _rebuild_neighborhood(center: Vector2i) -> void:
    if _roads == null:
        return
    for z in range(center.y - 1, center.y + 2):
        for x in range(center.x - 1, center.x + 2):
            var tile := Vector2i(x, z)
            var tile_root := _road_tile_root(tile)
            if tile_root == null:
                continue
            _build_tile(tile, tile_root, _segments_for_neighborhood(tile))

func _build_tile(tile: Vector2i, tile_root: Node3D, segments: Array) -> void:
    var existing := tile_root.get_node_or_null("RoadHairpinProxy")
    if existing != null:
        tile_root.remove_child(existing)
        existing.queue_free()
    var geometry := build_geometry(segments, tile, float(_roads.tile_size))
    var vertices: PackedVector3Array = geometry.vertices
    if vertices.is_empty():
        return
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = geometry.normals
    arrays[Mesh.ARRAY_COLOR] = geometry.colors
    arrays[Mesh.ARRAY_INDEX] = geometry.indices
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    mesh.surface_set_material(0, _apron_material())
    var proxy := Node3D.new()
    proxy.name = "RoadHairpinProxy"
    proxy.set_meta("source", "road-trace inferred mountain bend widening; not surveyed authority")
    proxy.set_meta("sharp_bends", int(geometry.sharp_bends))
    proxy.set_meta("hairpins", int(geometry.hairpins))
    proxy.set_meta("structural_skips", int(geometry.structural_skips))
    var instance := MeshInstance3D.new()
    instance.name = "RoadHairpinAprons"
    instance.mesh = mesh
    instance.visibility_range_end = VISIBILITY_RANGE_M
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    proxy.add_child(instance)
    var faces: PackedVector3Array = geometry.collision_faces
    if not faces.is_empty():
        var shape := ConcavePolygonShape3D.new()
        shape.set_faces(faces)
        shape.backface_collision = true
        var collider := CollisionShape3D.new()
        collider.shape = shape
        var body := StaticBody3D.new()
        body.name = "RoadHairpinCollision"
        body.collision_layer = 1
        body.collision_mask = 0
        body.add_child(collider)
        proxy.add_child(body)
    tile_root.add_child(proxy)

func build_geometry(segments: Array, tile: Vector2i, tile_size: float) -> Dictionary:
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var colors := PackedColorArray()
    var indices := PackedInt32Array()
    var faces := PackedVector3Array()
    var groups: Dictionary = {}
    var structural_skips := 0
    if tile_size <= 0.0 or not is_finite(tile_size):
        return _empty_geometry()
    var seen: Dictionary = {}
    for raw in segments:
        if not raw is Array or raw.size() < 12:
            continue
        var segment: Array = raw
        var flags := int(segment[6])
        if flags & (FLAG_BRIDGE | FLAG_TUNNEL):
            structural_skips += 1
            continue
        if float(segment[4]) < MIN_ROAD_WIDTH_M:
            continue
        var edge_id := str(segment[7])
        if edge_id.is_empty():
            continue
        # Neighbor tiles can carry the same unclipped source segment. Keep one
        # canonical copy so seam-aware gathering does not create duplicate bends.
        var segment_key := "%s:%s:%s:%s:%s:%s" % [edge_id, str(segment[8]), str(segment[0]),
            str(segment[1]), str(segment[2]), str(segment[3])]
        if seen.has(segment_key):
            continue
        seen[segment_key] = true
        if not groups.has(edge_id):
            groups[edge_id] = []
        groups[edge_id].append(segment)
    var sharp_bends := 0
    var hairpins := 0
    var origin := Vector2(float(tile.x) * tile_size, float(tile.y) * tile_size)
    for edge_segments: Array in groups.values():
        edge_segments.sort_custom(func(a: Array, b: Array) -> bool: return int(a[8]) < int(b[8]))
        for index in range(edge_segments.size() - 1):
            var first: Array = edge_segments[index]
            var second: Array = edge_segments[index + 1]
            if int(second[8]) != int(first[8]) + 1:
                continue
            # A seam bend may be visible to several loaded tiles. The averaged
            # graph joint owns it deterministically so exactly one tile emits it.
            if _bend_owner_tile(first, second, tile_size) != tile:
                continue
            var record := bend_record(first, second, origin)
            if record.is_empty():
                continue
            sharp_bends += 1
            if float(record.turn_deg) >= HAIRPIN_TURN_DEG:
                hairpins += 1
            _append_apron(record, vertices, normals, colors, indices, faces)
    return {"vertices": vertices, "normals": normals, "colors": colors, "indices": indices,
        "collision_faces": faces, "sharp_bends": sharp_bends, "hairpins": hairpins,
        "structural_skips": structural_skips}

func _bend_owner_tile(first: Array, second: Array, tile_size: float) -> Vector2i:
    if first.size() < 4 or second.size() < 2 or tile_size <= 0.0:
        return Vector2i(2147483647, 2147483647)
    var joint_a := Vector2(float(first[2]), float(first[3]))
    var joint_b := Vector2(float(second[0]), float(second[1]))
    var joint := (joint_a + joint_b) * 0.5
    return Vector2i(int(floor(joint.x / tile_size)), int(floor(joint.y / tile_size)))

func bend_record(first: Array, second: Array, tile_origin: Vector2 = Vector2.ZERO) -> Dictionary:
    if first.size() < 12 or second.size() < 12:
        return {}
    if int(first[6]) & (FLAG_BRIDGE | FLAG_TUNNEL) or int(second[6]) & (FLAG_BRIDGE | FLAG_TUNNEL):
        return {}
    var a := Vector2(float(first[0]), float(first[1]))
    var joint_a := Vector2(float(first[2]), float(first[3]))
    var joint_b := Vector2(float(second[0]), float(second[1]))
    var c := Vector2(float(second[2]), float(second[3]))
    if joint_a.distance_to(joint_b) > MAX_JUNCTION_GAP_M:
        return {}
    var d1 := joint_a - a
    var d2 := c - joint_b
    var len1 := d1.length()
    var len2 := d2.length()
    if len1 < MIN_SEGMENT_M or len2 < MIN_SEGMENT_M:
        return {}
    d1 /= len1
    d2 /= len2
    var turn_rad := acos(clampf(d1.dot(d2), -1.0, 1.0))
    var turn_deg := rad_to_deg(turn_rad)
    if turn_deg < MIN_TURN_DEG:
        return {}
    var cross := d1.x * d2.y - d1.y * d2.x
    if absf(cross) < 0.0001:
        return {}
    # A left bend has its outside shoulder to the right of travel and vice versa.
    var outside_sign := -signf(cross)
    var n1 := Vector2(-d1.y, d1.x) * outside_sign
    var n2 := Vector2(-d2.y, d2.x) * outside_sign
    var width := maxf(float(first[4]), float(second[4]))
    var half_width := width * 0.5
    var severity := clampf((turn_deg - MIN_TURN_DEG) / (150.0 - MIN_TURN_DEG), 0.0, 1.0)
    var widen := lerpf(MIN_WIDEN_M, MAX_WIDEN_M, severity)
    var approach := minf(8.0 + severity * 8.0, minf(len1, len2) * 0.72)
    if approach < 2.0:
        return {}
    var joint := (joint_a + joint_b) * 0.5
    var start_center := joint - d1 * approach
    var end_center := joint + d2 * approach
    var y_joint := (float(first[10]) + float(second[9])) * 0.5
    var y_start := lerpf(float(first[9]), float(first[10]), clampf((len1 - approach) / len1, 0.0, 1.0))
    var y_end := lerpf(float(second[9]), float(second[10]), clampf(approach / len2, 0.0, 1.0))
    var bisector := (n1 + n2).normalized()
    if bisector.length_squared() < 0.01:
        bisector = n1
    return {
        "turn_deg": turn_deg,
        "severity": severity,
        "widen_m": widen,
        "start_inner": _p3(start_center + n1 * half_width, y_start, tile_origin),
        "start_outer": _p3(start_center + n1 * (half_width + widen * 0.35), y_start - 0.018, tile_origin),
        "apex_inner": _p3(joint + bisector * half_width, y_joint, tile_origin),
        "apex_outer": _p3(joint + bisector * (half_width + widen), y_joint - 0.018, tile_origin),
        "end_inner": _p3(end_center + n2 * half_width, y_end, tile_origin),
        "end_outer": _p3(end_center + n2 * (half_width + widen * 0.35), y_end - 0.018, tile_origin),
    }

func _p3(point: Vector2, y: float, origin: Vector2) -> Vector3:
    return Vector3(point.x - origin.x, y, point.y - origin.y)

func _append_apron(record: Dictionary, vertices: PackedVector3Array, normals: PackedVector3Array,
        colors: PackedColorArray, indices: PackedInt32Array, faces: PackedVector3Array) -> void:
    var severity := float(record.severity)
    var color := Color(0.29, 0.285, 0.27, 1.0).lerp(Color(0.34, 0.325, 0.29, 1.0), severity)
    _append_quad(record.start_inner, record.start_outer, record.apex_outer, record.apex_inner,
        color, vertices, normals, colors, indices, faces)
    _append_quad(record.apex_inner, record.apex_outer, record.end_outer, record.end_inner,
        color, vertices, normals, colors, indices, faces)

func _append_quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, color: Color,
        vertices: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray,
        indices: PackedInt32Array, faces: PackedVector3Array) -> void:
    var normal := (b - a).cross(c - a)
    if normal.length_squared() < 0.0000001:
        return
    normal = normal.normalized()
    if normal.y < 0.0:
        normal = -normal
    var base := vertices.size()
    for point in [a, b, c, d]:
        vertices.append(point)
        normals.append(normal)
        colors.append(color)
    indices.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))
    faces.append_array(PackedVector3Array([a, b, c, a, c, d]))

func _empty_geometry() -> Dictionary:
    return {"vertices": PackedVector3Array(), "normals": PackedVector3Array(),
        "colors": PackedColorArray(), "indices": PackedInt32Array(),
        "collision_faces": PackedVector3Array(), "sharp_bends": 0, "hairpins": 0,
        "structural_skips": 0}

func _apron_material() -> StandardMaterial3D:
    if _material != null:
        return _material
    _material = StandardMaterial3D.new()
    _material.vertex_color_use_as_albedo = true
    _material.roughness = 0.92
    _material.metallic = 0.0
    _material.cull_mode = BaseMaterial3D.CULL_DISABLED
    return _material
