extends Node3D
class_name YardmanNearFieldRoadEdge

# Visual-only road/terrain reconciliation. Compiled road centreline/width and
# registered terrain remain authoritative. No terrain mutation or collision.
const BRIDGE_FLAG := 2
const TUNNEL_FLAG := 4
const UNPAVED_FLAG := 8
const ACTIVE_RADIUS_M := 230.0
const VISIBILITY_END_M := 165.0
const VISIBILITY_FADE_M := 22.0
const REBUILD_DISTANCE_M := 38.0
const MAX_SEGMENTS := 220
const CROSSING_MARGIN_M := 5.0

var _roads
var _terrain
var _hydrology
var _clock := 0.0
var _last_center := Vector2(INF, INF)
var _crossing_cache: Dictionary = {}
var _material: StandardMaterial3D

func _ready() -> void:
    call_deferred("_bind_sources")

func _process(delta: float) -> void:
    _clock += delta
    if _clock < 0.35:
        return
    _clock = 0.0
    if _roads == null or not is_instance_valid(_roads) or _terrain == null or not is_instance_valid(_terrain):
        _bind_sources()
        return
    var center := _canonical_target()
    if not center.is_finite():
        return
    if _last_center.is_finite() and center.distance_to(_last_center) < REBUILD_DISTANCE_M:
        return
    _rebuild(center)

func _exit_tree() -> void:
    _clear_detail()

func _bind_sources() -> void:
    var root := get_parent()
    if root == null:
        return
    _roads = root.get_node_or_null("JamaicaRoadStreamer")
    _terrain = root.get_node_or_null("JamaicaTerrainStreamer")
    _hydrology = root.get_node_or_null("JamaicaHydrologyRenderer")
    _last_center = Vector2(INF, INF)
    if _roads != null and _terrain != null:
        var center := _canonical_target()
        if center.is_finite():
            _rebuild(center)

func _canonical_target() -> Vector2:
    if _roads == null or not is_instance_valid(_roads) or _roads.target == null or _roads.coordinates == null:
        return Vector2(INF, INF)
    var world: PackedFloat64Array = _roads.coordinates.local_to_world(_roads.target.global_position)
    if world.size() < 3:
        return Vector2(INF, INF)
    return Vector2(float(world[0]), float(world[2]))

func _rebuild(center: Vector2) -> void:
    _last_center = center
    _clear_detail()
    # Without any hydrology truth we cannot safely distinguish an ordinary
    # verge from an unknown ford/water crossing. Fail closed until a pack is mounted.
    if _hydrology == null or not is_instance_valid(_hydrology):
        return
    var candidates: Dictionary = _roads._nearby_surface_segments(center.x, center.y, ACTIVE_RADIUS_M)
    var records: Array = candidates.values()
    records.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        return _record_midpoint(a).distance_squared_to(center) < _record_midpoint(b).distance_squared_to(center))
    var vertices := PackedVector3Array()
    var indices := PackedInt32Array()
    var normals := PackedVector3Array()
    var colors := PackedColorArray()
    var accepted := 0
    var rejected_crossing := 0
    var v2 := _hydrology.format_version() == 2
    for raw: Variant in records:
        if accepted >= MAX_SEGMENTS:
            break
        if not raw is Dictionary:
            continue
        var record: Dictionary = raw
        if not record_eligible(record):
            continue
        var a: Vector2 = record.get("a", Vector2(INF, INF))
        var b: Vector2 = record.get("b", Vector2(INF, INF))
        if not a.is_finite() or not b.is_finite() or a.distance_squared_to(b) < 1.0:
            continue
        var width_m := maxf(1.0, float(record.get("width_m", 5.5)))
        var blocked := false
        if v2:
            blocked = crossing_blocks_record(record, _v2_crossings_for_segment(a, b, width_m + CROSSING_MARGIN_M))
        else:
            blocked = _legacy_water_blocks_record(record)
        if blocked:
            rejected_crossing += 1
            continue
        var plans := shoulder_plan(record)
        var appended := false
        for plan: Dictionary in plans:
            if _append_plan(plan, vertices, indices, normals, colors):
                appended = true
        if appended:
            accepted += 1
    if vertices.is_empty():
        return
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = normals
    arrays[Mesh.ARRAY_COLOR] = colors
    arrays[Mesh.ARRAY_INDEX] = indices
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    mesh.surface_set_material(0, _road_edge_material())
    var instance := MeshInstance3D.new()
    instance.name = "RoadEdgeDetail"
    instance.mesh = mesh
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    instance.visibility_range_end = VISIBILITY_END_M
    instance.visibility_range_end_margin = VISIBILITY_FADE_M
    instance.set_meta("presentation_inference", true)
    instance.set_meta("source_contract", "compiled road width/centreline + registered terrain + hydrology crossing exclusions")
    instance.set_meta("collision", false)
    instance.set_meta("accepted_segments", accepted)
    instance.set_meta("crossing_rejections", rejected_crossing)
    instance.set_meta("hydrology_mode", "v2_crossings" if v2 else "legacy_water_fail_closed")
    add_child(instance)

func _clear_detail() -> void:
    var old := get_node_or_null("RoadEdgeDetail")
    if old != null:
        old.free()

func _append_plan(plan: Dictionary, vertices: PackedVector3Array, indices: PackedInt32Array,
        normals: PackedVector3Array, colors: PackedColorArray) -> bool:
    var canonical: Array = plan.get("points", [])
    if canonical.size() != 4 or _terrain == null or _roads == null or _roads.coordinates == null:
        return false
    var local_points: Array[Vector3] = []
    for raw: Variant in canonical:
        if not raw is Vector2:
            return false
        var point: Vector2 = raw
        var height := float(_terrain.height_at(point.x, point.y))
        if not is_finite(height) or height < -50.0:
            return false
        local_points.append(_roads.coordinates.world_to_local(point.x, point.y, height + float(plan.get("lift_m", 0.035))))
    var base := vertices.size()
    for point: Vector3 in local_points:
        vertices.append(point)
        normals.append(Vector3.UP)
        colors.append(plan.get("color", Color(0.45, 0.39, 0.29, 1.0)))
    indices.append_array(PackedInt32Array([base, base + 2, base + 1, base, base + 3, base + 2]))
    return true

func _legacy_water_blocks_record(record: Dictionary) -> bool:
    if _hydrology == null or not is_instance_valid(_hydrology):
        return true
    var a: Vector2 = record.get("a", Vector2(INF, INF))
    var b: Vector2 = record.get("b", Vector2(INF, INF))
    if not a.is_finite() or not b.is_finite():
        return true
    var width_m := maxf(1.0, float(record.get("width_m", 5.5)))
    var threshold := width_m * 0.5 + CROSSING_MARGIN_M
    for fraction in [0.15, 0.35, 0.5, 0.65, 0.85]:
        var point := a.lerp(b, float(fraction))
        if float(_hydrology.nearest_water_distance(point.x, point.y, threshold + 4.0)) <= threshold:
            return true
    return false

func _v2_crossings_for_segment(a: Vector2, b: Vector2, padding: float) -> Array:
    var result: Array = []
    if _hydrology == null or not is_instance_valid(_hydrology) or _hydrology.format_version() != 2:
        return result
    var size := float(_hydrology.tile_size)
    if size <= 0.0:
        return result
    var minimum := Vector2(minf(a.x, b.x) - padding, minf(a.y, b.y) - padding)
    var maximum := Vector2(maxf(a.x, b.x) + padding, maxf(a.y, b.y) + padding)
    var first := Vector2i(floori(minimum.x / size), floori(minimum.y / size))
    var last := Vector2i(floori(maximum.x / size), floori(maximum.y / size))
    for tz in range(first.y, last.y + 1):
        for tx in range(first.x, last.x + 1):
            result.append_array(_v2_crossings_for_tile(Vector2i(tx, tz)))
    return result

func _v2_crossings_for_tile(tile: Vector2i) -> Array:
    var key := "%d:%d" % [tile.x, tile.y]
    if _crossing_cache.has(key):
        return _crossing_cache[key]
    var found: Array = []
    if _hydrology == null or not is_instance_valid(_hydrology) or not _hydrology._tile_files.has(key):
        _crossing_cache[key] = found
        return found
    var filename := str(_hydrology._tile_files[key])
    if filename.is_empty() or filename.contains("/") or filename.contains("\\") or filename.contains(".."):
        _crossing_cache[key] = found
        return found
    var path := str(_hydrology.data_root).trim_suffix("/") + "/" + filename
    if not FileAccess.file_exists(path):
        _crossing_cache[key] = found
        return found
    var payload = JSON.parse_string(FileAccess.get_file_as_string(path))
    if not payload is Dictionary or int(payload.get("format_version", 0)) != 2:
        _crossing_cache[key] = found
        return found
    var seen: Dictionary = {}
    for raw: Variant in payload.get("structure_crossings", []):
        _append_crossing(found, seen, raw)
    for raw_segment: Variant in payload.get("segments", []):
        if raw_segment is Array and raw_segment.size() > 19:
            for raw: Variant in raw_segment[19]:
                _append_crossing(found, seen, raw)
    _crossing_cache[key] = found
    return found

static func _append_crossing(target: Array, seen: Dictionary, raw: Variant) -> void:
    if not raw is Dictionary:
        return
    var crossing: Dictionary = raw
    var x := float(crossing.get("x", INF))
    var z := float(crossing.get("z", INF))
    if not is_finite(x) or not is_finite(z):
        return
    var key := "%d:%d:%s:%s" % [roundi(x * 10.0), roundi(z * 10.0), str(crossing.get("kind", "")), str(crossing.get("status", ""))]
    if seen.has(key):
        return
    seen[key] = true
    target.append(crossing)

static func record_eligible(record: Dictionary) -> bool:
    var flags := int(record.get("flags", 0))
    return (flags & BRIDGE_FLAG) == 0 and (flags & TUNNEL_FLAG) == 0

static func crossing_blocks_record(record: Dictionary, crossings: Array) -> bool:
    var a: Vector2 = record.get("a", Vector2(INF, INF))
    var b: Vector2 = record.get("b", Vector2(INF, INF))
    if not a.is_finite() or not b.is_finite() or a.distance_squared_to(b) < 0.0001:
        return true
    var width_m := maxf(1.0, float(record.get("width_m", 5.5)))
    for raw: Variant in crossings:
        if not raw is Dictionary:
            continue
        var crossing: Dictionary = raw
        var point := Vector2(float(crossing.get("x", INF)), float(crossing.get("z", INF)))
        if not point.is_finite():
            continue
        var road_width := maxf(1.0, float(crossing.get("road_width_m", width_m)))
        var threshold := width_m * 0.5 + road_width * 0.5 + CROSSING_MARGIN_M
        if _point_segment_distance(point, a, b) <= threshold:
            # All reconciled crossing records are exclusion zones for this
            # presentation layer. This covers approved fords and also fails
            # closed for culverts/unresolved/conflicting evidence.
            return true
    return false

static func shoulder_plan(record: Dictionary) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    if not record_eligible(record):
        return result
    var a: Vector2 = record.get("a", Vector2(INF, INF))
    var b: Vector2 = record.get("b", Vector2(INF, INF))
    if not a.is_finite() or not b.is_finite():
        return result
    var delta := b - a
    if delta.length_squared() < 1.0:
        return result
    var width_m := maxf(1.0, float(record.get("width_m", 5.5)))
    var tangent := delta.normalized()
    var normal := Vector2(-tangent.y, tangent.x)
    var inner := width_m * 0.5 + 0.16
    var shoulder_width := clampf(width_m * 0.19, 0.85, 1.55)
    var outer := inner + shoulder_width
    var unpaved := (int(record.get("flags", 0)) & UNPAVED_FLAG) != 0
    var shoulder_color := Color(0.40, 0.35, 0.25, 1.0) if not unpaved else Color(0.34, 0.31, 0.23, 1.0)
    for side in [-1.0, 1.0]:
        var n := normal * float(side)
        result.append({"kind": "shoulder", "points": [a + n * inner, b + n * inner, b + n * outer, a + n * outer],
            "color": shoulder_color, "lift_m": 0.035})
    # Deterministic shallow drain/cut-edge strip on one side. It is only a
    # visual terrain seam cue; real culvert/water structures remain data-driven.
    var edge_id := str(record.get("edge_id", ""))
    if not unpaved and width_m >= 4.5 and (edge_id.hash() & 3) == 0:
        var side := -1.0 if (edge_id.hash() & 4) == 0 else 1.0
        var n := normal * side
        var drain_inner := outer + 0.22
        var drain_outer := drain_inner + 0.42
        result.append({"kind": "drain", "points": [a + n * drain_inner, b + n * drain_inner, b + n * drain_outer, a + n * drain_outer],
            "color": Color(0.20, 0.22, 0.17, 1.0), "lift_m": 0.022})
    return result

static func _record_midpoint(record: Dictionary) -> Vector2:
    var a: Vector2 = record.get("a", Vector2.ZERO)
    var b: Vector2 = record.get("b", Vector2.ZERO)
    return (a + b) * 0.5

static func _point_segment_distance(point: Vector2, a: Vector2, b: Vector2) -> float:
    var delta := b - a
    var length_squared := delta.length_squared()
    if length_squared <= 0.000001:
        return point.distance_to(a)
    var fraction := clampf((point - a).dot(delta) / length_squared, 0.0, 1.0)
    return point.distance_to(a + delta * fraction)

func _road_edge_material() -> StandardMaterial3D:
    if _material != null:
        return _material
    _material = StandardMaterial3D.new()
    _material.vertex_color_use_as_albedo = true
    _material.roughness = 0.96
    return _material
