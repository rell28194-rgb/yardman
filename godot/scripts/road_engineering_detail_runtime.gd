extends Node

# Evidence-driven roadside engineering detail. This layer does not invent surveyed
# structures: it reads the stable road deck against Jamaica's DEM and adds a narrow
# bench only where a deep cut/fill transition implies an engineered hillside tie.
# Explicit bridges, tunnels, retaining walls and guard rails remain authoritative.
const FLAG_BRIDGE := 2
const FLAG_TUNNEL := 4
const SAMPLE_STEP_M := 18.0
const MIN_SHOULDER_M := 0.65
const MAX_SHOULDER_M := 1.35
const MIN_TIE_RUN_M := 3.5
const MAX_TIE_RUN_M := 18.0
const DEEP_EARTHWORK_THRESHOLD_M := 2.20
const BENCH_WIDTH_M := 1.05
const BENCH_RUN_FRACTION := 0.56
const MAX_SEGMENTS_PER_TILE := 1800
const VISIBILITY_RANGE_M := 1400.0
const SURFACE_LIFT_M := 0.028

var _roads: Node
var _terrain: Node
var _connected := false
var _segments_by_tile: Dictionary = {}
var _material: StandardMaterial3D

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
    _terrain = scene.get_node_or_null("JamaicaTerrainStreamer")
    if _roads == null or _terrain == null:
        return
    _roads.tile_content_ready.connect(_on_road_tile)
    _roads.tile_removed.connect(_on_road_tile_removed)
    _terrain.tile_ready.connect(_on_terrain_tile)
    _terrain.tile_removed.connect(_on_terrain_tile_removed)
    _connected = true
    set_process(false)

func _on_road_tile(tile: Vector2i, _tile_root: Node3D, segments: Array) -> void:
    _segments_by_tile[tile] = segments.duplicate(false)
    _try_build(tile)

func _on_road_tile_removed(tile: Vector2i) -> void:
    _segments_by_tile.erase(tile)

func _on_terrain_tile(tile: Vector2i) -> void:
    _try_build(tile)

func _on_terrain_tile_removed(tile: Vector2i) -> void:
    var tile_root := _road_tile_root(tile)
    if tile_root == null:
        return
    var existing := tile_root.get_node_or_null("RoadEngineeringDetailProxy")
    if existing != null:
        tile_root.remove_child(existing)
        existing.queue_free()

func _road_tile_root(tile: Vector2i) -> Node3D:
    if _roads == null:
        return null
    var key = _roads._tile_key(tile.x, tile.y)
    return _roads._loaded.get(key) as Node3D

func _try_build(tile: Vector2i) -> void:
    if _terrain == null or not _terrain.is_tile_ready(tile) or not _segments_by_tile.has(tile):
        return
    var tile_root := _road_tile_root(tile)
    if tile_root == null:
        return
    _decorate(tile, tile_root, _segments_by_tile[tile])

func _decorate(tile: Vector2i, tile_root: Node3D, segments: Array) -> void:
    var existing := tile_root.get_node_or_null("RoadEngineeringDetailProxy")
    if existing != null:
        tile_root.remove_child(existing)
        existing.queue_free()
    var geometry := build_geometry(segments, tile, float(_roads.tile_size), _terrain.height_at)
    var vertices: PackedVector3Array = geometry.get("vertices", PackedVector3Array())
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
    mesh.surface_set_material(0, _bench_material())

    var proxy := Node3D.new()
    proxy.name = "RoadEngineeringDetailProxy"
    proxy.set_meta("source", "road deck + Jamaica DEM inference")
    proxy.set_meta("rule", "deep cut/fill bench only; explicit structures remain authoritative")
    proxy.set_meta("cut_bench_spans", int(geometry.get("cut_bench_spans", 0)))
    proxy.set_meta("fill_bench_spans", int(geometry.get("fill_bench_spans", 0)))
    proxy.set_meta("structural_skips", int(geometry.get("structural_skips", 0)))
    var instance := MeshInstance3D.new()
    instance.name = "RoadEngineeringDetailMesh"
    instance.mesh = mesh
    instance.visibility_range_end = VISIBILITY_RANGE_M
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    proxy.add_child(instance)
    tile_root.add_child(proxy)

func build_geometry(segments: Array, tile: Vector2i, tile_size: float, height_sampler: Callable,
        sample_step_m: float = SAMPLE_STEP_M) -> Dictionary:
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var colors := PackedColorArray()
    var indices := PackedInt32Array()
    var cut_bench_spans := 0
    var fill_bench_spans := 0
    var structural_skips := 0
    if tile_size <= 0.0 or sample_step_m <= 0.0 or not is_finite(tile_size) or not is_finite(sample_step_m) or not height_sampler.is_valid():
        return {"vertices": vertices, "normals": normals, "colors": colors, "indices": indices,
            "cut_bench_spans": 0, "fill_bench_spans": 0, "structural_skips": 0}
    var seen: Dictionary = {}
    var processed := 0
    for segment in segments:
        if processed >= MAX_SEGMENTS_PER_TILE:
            break
        if not segment is Array or segment.size() < 12:
            continue
        var flags := int(segment[6])
        if flags & (FLAG_BRIDGE | FLAG_TUNNEL):
            structural_skips += 1
            continue
        var identifier := "%s:%s:%s:%s:%s:%s" % [str(segment[7]), str(segment[8]), str(segment[0]), str(segment[1]), str(segment[2]), str(segment[3])]
        if seen.has(identifier):
            continue
        seen[identifier] = true
        var sections := segment_benches(segment, tile, tile_size, height_sampler, sample_step_m)
        if sections.size() < 2:
            continue
        processed += 1
        for index in range(sections.size() - 1):
            var a: Dictionary = sections[index]
            var b: Dictionary = sections[index + 1]
            for side_name in ["left", "right"]:
                if not a.has(side_name) or not b.has(side_name):
                    continue
                var pa: Dictionary = a[side_name]
                var pb: Dictionary = b[side_name]
                var kind := str(pa.get("kind", ""))
                if kind.is_empty() or kind != str(pb.get("kind", "")):
                    continue
                var color := Color(0.36, 0.27, 0.17, 1.0) if kind == "cut" else Color(0.30, 0.35, 0.20, 1.0)
                _append_quad(pa.inner, pa.outer, pb.outer, pb.inner, color, vertices, normals, colors, indices)
                if kind == "cut":
                    cut_bench_spans += 1
                else:
                    fill_bench_spans += 1
    return {"vertices": vertices, "normals": normals, "colors": colors, "indices": indices,
        "cut_bench_spans": cut_bench_spans, "fill_bench_spans": fill_bench_spans,
        "structural_skips": structural_skips}

func segment_benches(segment: Array, tile: Vector2i, tile_size: float, height_sampler: Callable,
        sample_step_m: float = SAMPLE_STEP_M) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    if segment.size() < 12 or tile_size <= 0.0 or sample_step_m <= 0.0 or not height_sampler.is_valid():
        return result
    var flags := int(segment[6])
    if flags & (FLAG_BRIDGE | FLAG_TUNNEL):
        return result
    var a := Vector2(float(segment[0]), float(segment[1]))
    var b := Vector2(float(segment[2]), float(segment[3]))
    var delta := b - a
    var length := delta.length()
    var width := float(segment[4])
    var start_y := float(segment[9])
    var end_y := float(segment[10])
    if length < 0.05 or width < 1.0 or not is_finite(start_y) or not is_finite(end_y):
        return result
    var polygon = segment[11]
    if not polygon is Array or polygon.size() < 3:
        return result
    var tangent := delta / length
    var right := Vector2(-tangent.y, tangent.x)
    var visible_start := length
    var visible_end := 0.0
    var found := false
    for raw_point in polygon:
        if not raw_point is Array or raw_point.size() < 3:
            continue
        var p := Vector2(float(raw_point[0]), float(raw_point[2]))
        if not is_finite(p.x) or not is_finite(p.y):
            continue
        var station := clampf((p - a).dot(tangent), 0.0, length)
        visible_start = minf(visible_start, station)
        visible_end = maxf(visible_end, station)
        found = true
    if not found or visible_end - visible_start < 0.04:
        return result
    var steps := maxi(1, int(ceil((visible_end - visible_start) / sample_step_m)))
    var half_width := width * 0.5
    var shoulder := clampf(width * 0.10, MIN_SHOULDER_M, MAX_SHOULDER_M)
    var tile_origin := Vector2(float(tile.x) * tile_size, float(tile.y) * tile_size)
    for index in range(steps + 1):
        var alpha := float(index) / float(steps)
        var station := lerpf(visible_start, visible_end, alpha)
        var t := clampf(station / length, 0.0, 1.0)
        var center := a + tangent * station
        var deck_y := lerpf(start_y, end_y, t)
        var section: Dictionary = {"station": station}
        var left := _bench_profile(center, deck_y, right, -1.0, half_width, shoulder, tile_origin, height_sampler)
        var right_profile := _bench_profile(center, deck_y, right, 1.0, half_width, shoulder, tile_origin, height_sampler)
        if not left.is_empty():
            section["left"] = left
        if not right_profile.is_empty():
            section["right"] = right_profile
        result.append(section)
    return result

func _bench_profile(center: Vector2, deck_y: float, right_axis: Vector2, side: float,
        half_width: float, shoulder: float, tile_origin: Vector2, height_sampler: Callable) -> Dictionary:
    var shoulder_offset := half_width + shoulder
    var probe_offset := shoulder_offset + 6.0
    var probe_world := center + right_axis * side * probe_offset
    var probe_ground := float(height_sampler.call(probe_world.x, probe_world.y))
    if not is_finite(probe_ground):
        return {}
    var tie_run := clampf(3.0 + absf(probe_ground - deck_y) * 1.35, MIN_TIE_RUN_M, MAX_TIE_RUN_M)
    var tie_offset := shoulder_offset + tie_run
    var tie_world := center + right_axis * side * tie_offset
    var tie_ground := float(height_sampler.call(tie_world.x, tie_world.y))
    if not is_finite(tie_ground):
        return {}
    var delta_y := tie_ground - deck_y
    if absf(delta_y) < DEEP_EARTHWORK_THRESHOLD_M:
        return {}
    var kind := "cut" if delta_y > 0.0 else "fill"
    var center_offset := shoulder_offset + tie_run * BENCH_RUN_FRACTION
    var fraction := clampf((center_offset - shoulder_offset) / maxf(tie_run, 0.001), 0.0, 1.0)
    var bench_y := lerpf(deck_y - 0.035, tie_ground + 0.018, fraction) + SURFACE_LIFT_M
    var half_bench := minf(BENCH_WIDTH_M * 0.5, tie_run * 0.18)
    var inner_offset := maxf(shoulder_offset + 0.20, center_offset - half_bench)
    var outer_offset := minf(tie_offset - 0.20, center_offset + half_bench)
    if outer_offset - inner_offset < 0.25:
        return {}
    var inner_world := center + right_axis * side * inner_offset
    var outer_world := center + right_axis * side * outer_offset
    return {
        "kind": kind,
        "delta_y": delta_y,
        "inner": Vector3(inner_world.x - tile_origin.x, bench_y, inner_world.y - tile_origin.y),
        "outer": Vector3(outer_world.x - tile_origin.x, bench_y, outer_world.y - tile_origin.y),
    }

func _append_quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, color: Color,
        vertices: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray,
        indices: PackedInt32Array) -> void:
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

func _bench_material() -> StandardMaterial3D:
    if _material != null:
        return _material
    _material = StandardMaterial3D.new()
    _material.vertex_color_use_as_albedo = true
    _material.roughness = 0.98
    _material.metallic = 0.0
    _material.cull_mode = BaseMaterial3D.CULL_DISABLED
    return _material
