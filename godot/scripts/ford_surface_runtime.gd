extends Node3D
class_name YardmanFordSurfaceRuntime

# Approved v2 fords are at-grade water/road crossings. The base hydrology ribbon
# stays continuous; this bounded overlay only raises a shallow water skin above
# the road render surface so asphalt/gravel no longer visually cuts the stream.
const FordShader = preload("res://shaders/ford_surface.gdshader")
const References = preload("res://scripts/reference_assets.gd")
const MeshGeometryGuard = preload("res://scripts/mesh_geometry_guard.gd")
const GRAVEL_ASSET := "road_gravel.png"
const MAX_FORDS := 24
const MAX_FORDS_PER_TILE := 8
const VISIBILITY_END_M := 190.0
const VISIBILITY_FADE_M := 28.0
const ROAD_LOOKUP_RADIUS_M := 48.0
const ROAD_CENTER_TOLERANCE_M := 0.35
const ROAD_WIDTH_TOLERANCE_M := 0.05
const ROAD_OVERLAP_M := 0.55
const MIN_CROSSING_NORMAL_DOT := 0.25
const MAX_OBLIQUE_FACTOR := 4.0
const MAX_HALF_PATH_M := 35.0
const FORD_SURFACE_LIFT_M := 0.195

var _hydrology
var _roads
var _material: ShaderMaterial
var _clock := 0.0
var _signature := ""

func _ready() -> void:
    call_deferred("_bind")

func _process(delta: float) -> void:
    _clock += delta
    if _clock < 0.45:
        return
    _clock = 0.0
    if _hydrology == null or not is_instance_valid(_hydrology) or _roads == null or not is_instance_valid(_roads):
        _bind()
        return
    var next := _state_signature()
    if next != _signature:
        _signature = next
        _rebuild()

func _bind() -> void:
    var root := get_parent()
    if root == null:
        return
    _hydrology = root.get_node_or_null("JamaicaHydrologyRenderer")
    _roads = root.get_node_or_null("JamaicaRoadStreamer")
    if _hydrology == null or _roads == null:
        return
    _signature = ""
    _rebuild()
    _signature = _state_signature()

func _state_signature() -> String:
    if _hydrology == null or _roads == null or _roads.coordinates == null:
        return ""
    var hydro_keys: Array[String] = []
    for raw: Variant in _hydrology._loaded.keys():
        hydro_keys.append(str(raw))
    hydro_keys.sort()
    var road_keys: Array[String] = []
    for raw: Variant in _roads._surface_indices.keys():
        road_keys.append(str(raw))
    road_keys.sort()
    var coordinates = _roads.coordinates
    return "%s|%s|%.1f|%.1f|%d" % [",".join(hydro_keys), ",".join(road_keys),
        float(coordinates.render_origin_x), float(coordinates.render_origin_z), int(_hydrology.format_version())]

func _clear() -> void:
    var old := get_node_or_null("ReconciledFords")
    if old != null:
        old.free()

func _rebuild() -> void:
    _clear()
    if _hydrology == null or _roads == null or _roads.coordinates == null or int(_hydrology.format_version()) != 2:
        return
    var root := Node3D.new()
    root.name = "ReconciledFords"
    root.set_meta("source_contract", "approved reconciled v2 ford + exact compiled road edge/tangent/width + continuous compiled water segment")
    root.set_meta("water_clipping", false)
    root.set_meta("terrain_mutation", false)
    root.set_meta("road_mutation", false)
    root.set_meta("collision", false)
    var seen: Dictionary = {}
    var total := 0
    var loaded_keys: Array[String] = []
    for raw_key: Variant in _hydrology._loaded.keys():
        loaded_keys.append(str(raw_key))
    loaded_keys.sort()
    for key: String in loaded_keys:
        if total >= MAX_FORDS:
            break
        if not _hydrology._tile_files.has(key):
            continue
        var filename := str(_hydrology._tile_files[key])
        if filename.is_empty() or filename.contains("/") or filename.contains("\\") or filename.contains(".."):
            continue
        var path := str(_hydrology.data_root).trim_suffix("/") + "/" + filename
        if not FileAccess.file_exists(path):
            continue
        var payload = JSON.parse_string(FileAccess.get_file_as_string(path))
        if not payload is Dictionary or int(payload.get("format_version", 0)) != 2:
            continue
        var tile_raw: Array = payload.get("tile", [])
        if tile_raw.size() != 2:
            continue
        var tile := Vector2i(int(tile_raw[0]), int(tile_raw[1]))
        var tile_world := Vector2(float(tile.x) * float(_hydrology.tile_size), float(tile.y) * float(_hydrology.tile_size))
        var surface := SurfaceTool.new()
        surface.begin(Mesh.PRIMITIVE_TRIANGLES)
        var tile_count := 0
        for raw_segment: Variant in payload.get("segments", []):
            if total >= MAX_FORDS or tile_count >= MAX_FORDS_PER_TILE:
                break
            if not raw_segment is Array or raw_segment.size() < 20:
                continue
            var segment: Array = raw_segment
            var water_a := Vector3(tile_world.x + float(segment[0]), float(segment[1]), tile_world.y + float(segment[2]))
            var water_b := Vector3(tile_world.x + float(segment[3]), float(segment[4]), tile_world.y + float(segment[5]))
            var water_width := clampf(float(segment[9]), 0.7, 45.0)
            if not water_a.is_finite() or not water_b.is_finite():
                continue
            var crossings: Array = segment[19] if segment[19] is Array else []
            for raw_crossing: Variant in crossings:
                if total >= MAX_FORDS or tile_count >= MAX_FORDS_PER_TILE:
                    break
                if not raw_crossing is Dictionary:
                    continue
                var crossing: Dictionary = raw_crossing
                if not ford_eligible(crossing):
                    continue
                var identity := ford_identity(crossing)
                if identity.is_empty() or seen.has(identity):
                    continue
                var road_record := _resolve_road_record(crossing)
                if road_record.is_empty():
                    continue
                var plan := ford_plan(crossing, water_a, water_b, water_width, road_record)
                if plan.is_empty():
                    continue
                _append_plan(surface, plan)
                seen[identity] = true
                total += 1
                tile_count += 1
        if tile_count <= 0:
            continue
        surface.index()
        var mesh := surface.commit()
        if mesh == null or mesh.get_surface_count() == 0:
            continue
        var arrays: Array = mesh.surface_get_arrays(0)
        var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
        var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
        var safety := MeshGeometryGuard.validate(vertices, indices, float(_hydrology.tile_size) * 1.75, 128.0, 2048)
        if not bool(safety.get("ok", false)):
            push_error(MeshGeometryGuard.rejection_message("ford tile %s" % key, safety))
            continue
        mesh.surface_set_material(0, _ford_material())
        var instance := MeshInstance3D.new()
        instance.name = "Ford_%s" % key.replace(":", "_")
        instance.mesh = mesh
        instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        instance.visibility_range_end = VISIBILITY_END_M
        instance.visibility_range_end_margin = VISIBILITY_FADE_M
        instance.set_meta("ford_count", tile_count)
        instance.set_meta("continuous_water", true)
        instance.set_meta("collision", false)
        root.add_child(instance)
    if root.get_child_count() > 0:
        root.set_meta("ford_count", total)
        add_child(root)
    else:
        root.free()

func _resolve_road_record(crossing: Dictionary) -> Dictionary:
    if _roads == null or not is_instance_valid(_roads):
        return {}
    var records: Dictionary = _roads._nearby_surface_segments(float(crossing.get("x", NAN)),
        float(crossing.get("z", NAN)), ROAD_LOOKUP_RADIUS_M)
    return select_road_record(crossing, records.values())

func _append_plan(surface: SurfaceTool, plan: Dictionary) -> void:
    var start_world: Vector3 = plan.start
    var finish_world: Vector3 = plan.finish
    var side_world: Vector2 = plan.side
    var half_width := float(plan.surface_width_m) * 0.5
    var start_local: Vector3 = _roads.coordinates.world_to_local(start_world.x, start_world.z, start_world.y)
    var finish_local: Vector3 = _roads.coordinates.world_to_local(finish_world.x, finish_world.z, finish_world.y)
    var side := Vector3(side_world.x, 0.0, side_world.y) * half_width
    var unpaved := 1.0 if bool(plan.unpaved) else 0.0
    var color := Color(unpaved, 0.0, 0.0, 1.0)
    _triangle(surface, start_local + side, Vector2(0.0, 0.0), finish_local + side, Vector2(0.0, 1.0),
        start_local - side, Vector2(1.0, 0.0), color)
    _triangle(surface, start_local - side, Vector2(1.0, 0.0), finish_local + side, Vector2(0.0, 1.0),
        finish_local - side, Vector2(1.0, 1.0), color)

func _triangle(surface: SurfaceTool, a: Vector3, uv_a: Vector2, b: Vector3, uv_b: Vector2,
        c: Vector3, uv_c: Vector2, color: Color) -> void:
    for item in [[a, uv_a], [b, uv_b], [c, uv_c]]:
        surface.set_normal(Vector3.UP)
        surface.set_color(color)
        surface.set_uv(item[1])
        surface.add_vertex(item[0])

func _ford_material() -> ShaderMaterial:
    if _material != null:
        return _material
    _material = ShaderMaterial.new()
    _material.shader = FordShader
    var gravel := References.texture(GRAVEL_ASSET)
    if gravel != null:
        _material.set_shader_parameter("reference_gravel", gravel)
        _material.set_shader_parameter("has_reference_gravel", true)
    return _material

static func _segment_distance_squared(point: Vector2, a: Vector2, b: Vector2) -> float:
    var direction := b - a
    var length_squared := direction.length_squared()
    if length_squared < 0.000001:
        return point.distance_squared_to(a)
    var fraction := clampf((point - a).dot(direction) / length_squared, 0.0, 1.0)
    return point.distance_squared_to(a + direction * fraction)

static func ford_eligible(crossing: Dictionary) -> bool:
    return str(crossing.get("status", "unresolved")) == "approved" \
        and str(crossing.get("kind", "unknown")) == "ford" \
        and is_finite(float(crossing.get("x", NAN))) \
        and is_finite(float(crossing.get("z", NAN))) \
        and not str(crossing.get("road_edge", "")).is_empty() \
        and float(crossing.get("road_width_m", 0.0)) > 0.0

static func ford_identity(crossing: Dictionary) -> String:
    if not ford_eligible(crossing):
        return ""
    return "%d:%d:%s" % [roundi(float(crossing.x) * 10.0), roundi(float(crossing.z) * 10.0), str(crossing.road_edge)]

static func select_road_record(crossing: Dictionary, records: Array) -> Dictionary:
    if not ford_eligible(crossing):
        return {}
    var expected_edge := str(crossing.road_edge)
    var expected_width := float(crossing.road_width_m)
    var point := Vector2(float(crossing.x), float(crossing.z))
    var best: Dictionary = {}
    var best_distance_squared := INF
    for raw: Variant in records:
        if not raw is Dictionary:
            continue
        var record: Dictionary = raw
        if str(record.get("edge_id", "")) != expected_edge:
            continue
        var flags := int(record.get("flags", 0))
        if (flags & 2) != 0 or (flags & 4) != 0:
            continue
        var width := float(record.get("width_m", NAN))
        if not is_finite(width) or absf(width - expected_width) > ROAD_WIDTH_TOLERANCE_M:
            continue
        var a: Vector2 = record.get("a", Vector2(INF, INF))
        var b: Vector2 = record.get("b", Vector2(INF, INF))
        if not a.is_finite() or not b.is_finite() or a.distance_squared_to(b) < 0.25:
            continue
        var distance_squared := _segment_distance_squared(point, a, b)
        if distance_squared < best_distance_squared:
            best_distance_squared = distance_squared
            best = record
    if best.is_empty() or best_distance_squared > ROAD_CENTER_TOLERANCE_M * ROAD_CENTER_TOLERANCE_M:
        return {}
    return best.duplicate(true)

static func ford_plan(crossing: Dictionary, water_a: Vector3, water_b: Vector3, water_width_m: float,
        road_record: Dictionary = {}) -> Dictionary:
    if not ford_eligible(crossing) or road_record.is_empty() or not water_a.is_finite() or not water_b.is_finite() or not is_finite(water_width_m):
        return {}
    var water_delta := Vector2(water_b.x - water_a.x, water_b.z - water_a.z)
    var water_length := water_delta.length()
    if water_length < 0.5:
        return {}
    var channel := water_delta / water_length
    var side := Vector2(-channel.y, channel.x)
    var crossing_point := Vector2(float(crossing.x), float(crossing.z))
    var water_origin := Vector2(water_a.x, water_a.z)
    var t := clampf((crossing_point - water_origin).dot(water_delta) / (water_length * water_length), 0.0, 1.0)
    var nearest := water_origin + water_delta * t
    if nearest.distance_to(crossing_point) > 1.25:
        return {}

    var road_a: Vector2 = road_record.get("a", Vector2(INF, INF))
    var road_b: Vector2 = road_record.get("b", Vector2(INF, INF))
    var road_delta := road_b - road_a
    if not road_a.is_finite() or not road_b.is_finite() or road_delta.length_squared() < 0.25:
        return {}
    if str(road_record.get("edge_id", "")) != str(crossing.road_edge):
        return {}
    var road_width := float(road_record.get("width_m", NAN))
    if not is_finite(road_width) or absf(road_width - float(crossing.road_width_m)) > ROAD_WIDTH_TOLERANCE_M:
        return {}
    if _segment_distance_squared(crossing_point, road_a, road_b) > ROAD_CENTER_TOLERANCE_M * ROAD_CENTER_TOLERANCE_M:
        return {}
    var road_tangent := road_delta.normalized()
    var road_normal := Vector2(-road_tangent.y, road_tangent.x)
    var normal_dot := absf(channel.dot(road_normal))
    if normal_dot < MIN_CROSSING_NORMAL_DOT:
        return {}
    var oblique_factor := 1.0 / normal_dot
    if not is_finite(oblique_factor) or oblique_factor > MAX_OBLIQUE_FACTOR + 0.0001:
        return {}
    var half_path := (road_width * 0.5 + ROAD_OVERLAP_M) * oblique_factor
    if not is_finite(half_path) or half_path > MAX_HALF_PATH_M:
        return {}

    var center_y := lerpf(water_a.y, water_b.y, t)
    var grade_per_m := (water_b.y - water_a.y) / water_length
    var start_point := crossing_point - channel * half_path
    var finish_point := crossing_point + channel * half_path
    var start_y := center_y - grade_per_m * half_path + FORD_SURFACE_LIFT_M
    var finish_y := center_y + grade_per_m * half_path + FORD_SURFACE_LIFT_M
    if not is_finite(start_y) or not is_finite(finish_y):
        return {}
    return {
        "start": Vector3(start_point.x, start_y, start_point.y),
        "finish": Vector3(finish_point.x, finish_y, finish_point.y),
        "channel_dir": channel,
        "side": side,
        "road_tangent": road_tangent,
        "road_normal": road_normal,
        "road_edge": str(crossing.road_edge),
        "road_width_m": road_width,
        "water_width_m": clampf(water_width_m, 0.7, 18.0),
        "surface_width_m": clampf(water_width_m * 1.03, 0.75, 18.5),
        "half_path_m": half_path,
        "oblique_factor": oblique_factor,
        "surface_lift_m": FORD_SURFACE_LIFT_M,
        "unpaved": (int(road_record.get("flags", 0)) & 8) != 0,
        "continuous_water": true,
        "source_unchanged": true,
    }

static func runtime_contract() -> Dictionary:
    return {
        "format_version": 2,
        "status": "approved",
        "kind": "ford",
        "max_fords": MAX_FORDS,
        "max_fords_per_tile": MAX_FORDS_PER_TILE,
        "visibility_m": VISIBILITY_END_M,
        "gravel_asset": GRAVEL_ASSET,
        "surface_lift_m": FORD_SURFACE_LIFT_M,
        "continuous_base_water": true,
        "water_clipping": false,
        "exact_road_edge_required": true,
        "oblique_road_edges": true,
        "terrain_mutation": false,
        "hydrology_mutation": false,
        "road_mutation": false,
        "collision": false,
        "shadows": false,
    }
