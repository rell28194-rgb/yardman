extends Node

# Road surfaces keep a stable longitudinal deck. This runtime supplies the missing
# transition between that deck and Jamaica's DEM terrain: shoulders, cut/fill
# tie-ins, benched mountain earthworks and cut-side drainage. Bridges and tunnels
# are excluded because their terrain relationship is handled by structural/portal systems.
const FLAG_BRIDGE := 2
const FLAG_TUNNEL := 4
const SAMPLE_STEP_M := 12.0
const MIN_SHOULDER_M := 0.65
const MAX_SHOULDER_M := 1.35
const MIN_TIE_RUN_M := 3.5
const MAX_TIE_RUN_M := 18.0
const CUT_DITCH_THRESHOLD_M := 0.60
const DITCH_DEPTH_M := 0.28
const DITCH_RUN_M := 1.15
const CUT_BENCH_THRESHOLD_M := 3.0
const FILL_BENCH_THRESHOLD_M := 3.0
const BENCH_WIDTH_M := 1.60
const BENCH_MIN_CLEAR_M := 0.75
const MAX_SEGMENTS_PER_TILE := 2400
const VISIBILITY_RANGE_M := 1600.0

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
    var existing := tile_root.get_node_or_null("RoadEarthworksProxy")
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
    var existing := tile_root.get_node_or_null("RoadEarthworksProxy")
    if existing != null:
        tile_root.remove_child(existing)
        existing.queue_free()

    var geometry := build_geometry(segments, tile, float(_roads.tile_size), _terrain.height_at)
    var vertices: PackedVector3Array = geometry.get("vertices", PackedVector3Array())
    if vertices.is_empty():
        return

    var mesh := ArrayMesh.new()
    var arrays := []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = geometry.normals
    arrays[Mesh.ARRAY_COLOR] = geometry.colors
    arrays[Mesh.ARRAY_INDEX] = geometry.indices
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    mesh.surface_set_material(0, _earth_material())

    var proxy := Node3D.new()
    proxy.name = "RoadEarthworksProxy"
    proxy.set_meta("source", "road deck + Jamaica DEM terrain")
    proxy.set_meta("segments", int(geometry.get("segments", 0)))
    proxy.set_meta("cut_profiles", int(geometry.get("cut_profiles", 0)))
    proxy.set_meta("fill_profiles", int(geometry.get("fill_profiles", 0)))
    proxy.set_meta("drainage_profiles", int(geometry.get("drainage_profiles", 0)))
    proxy.set_meta("bench_profiles", int(geometry.get("bench_profiles", 0)))
    proxy.set_meta("cut_bench_profiles", int(geometry.get("cut_bench_profiles", 0)))
    proxy.set_meta("fill_bench_profiles", int(geometry.get("fill_bench_profiles", 0)))
    proxy.set_meta("bridge_tunnel_skips", int(geometry.get("structural_skips", 0)))

    var instance := MeshInstance3D.new()
    instance.name = "RoadEarthworksMesh"
    instance.mesh = mesh
    instance.visibility_range_end = VISIBILITY_RANGE_M
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    proxy.add_child(instance)

    var collision_faces: PackedVector3Array = geometry.get("collision_faces", PackedVector3Array())
    if not collision_faces.is_empty():
        var body := StaticBody3D.new()
        body.name = "RoadEarthworksCollision"
        body.collision_layer = 1
        body.collision_mask = 0
        var shape := ConcavePolygonShape3D.new()
        shape.set_faces(collision_faces)
        shape.backface_collision = true
        var collider := CollisionShape3D.new()
        collider.shape = shape
        body.add_child(collider)
        proxy.add_child(body)
    tile_root.add_child(proxy)

func build_geometry(segments: Array, tile: Vector2i, tile_size: float, height_sampler: Callable,
        sample_step_m: float = SAMPLE_STEP_M) -> Dictionary:
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var colors := PackedColorArray()
    var indices := PackedInt32Array()
    var collision_faces := PackedVector3Array()
    var segment_count := 0
    var cut_profiles := 0
    var fill_profiles := 0
    var drainage_profiles := 0
    var bench_profiles := 0
    var cut_bench_profiles := 0
    var fill_bench_profiles := 0
    var structural_skips := 0
    if tile_size <= 0.0 or sample_step_m <= 0.0 or not is_finite(tile_size) or not is_finite(sample_step_m) or not height_sampler.is_valid():
        return {"vertices": vertices, "normals": normals, "colors": colors, "indices": indices,
            "collision_faces": collision_faces, "segments": 0, "cut_profiles": 0, "fill_profiles": 0,
            "drainage_profiles": 0, "bench_profiles": 0, "cut_bench_profiles": 0,
            "fill_bench_profiles": 0, "structural_skips": 0}

    var seen: Dictionary = {}
    for segment in segments:
        if segment_count >= MAX_SEGMENTS_PER_TILE:
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
        var sections: Array[Dictionary] = segment_sections(segment, tile, tile_size, height_sampler, sample_step_m)
        if sections.size() < 2:
            continue
        segment_count += 1
        for section: Dictionary in sections:
            for side_name in ["left", "right"]:
                var profile: Dictionary = section.get(side_name, {})
                var kind := str(profile.get("kind", "blend"))
                if kind == "cut":
                    cut_profiles += 1
                elif kind == "fill":
                    fill_profiles += 1
                if profile.has("ditch"):
                    drainage_profiles += 1
                if profile.has("bench_inner") and profile.has("bench_outer"):
                    bench_profiles += 1
                    if kind == "cut":
                        cut_bench_profiles += 1
                    elif kind == "fill":
                        fill_bench_profiles += 1
        _append_segment_geometry(sections, vertices, normals, colors, indices, collision_faces)

    return {"vertices": vertices, "normals": normals, "colors": colors, "indices": indices,
        "collision_faces": collision_faces, "segments": segment_count, "cut_profiles": cut_profiles,
        "fill_profiles": fill_profiles, "drainage_profiles": drainage_profiles,
        "bench_profiles": bench_profiles, "cut_bench_profiles": cut_bench_profiles,
        "fill_bench_profiles": fill_bench_profiles, "structural_skips": structural_skips}

func segment_sections(segment: Array, tile: Vector2i, tile_size: float, height_sampler: Callable,
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
    if length < 0.05 or width < 1.0 or not is_finite(length) or not is_finite(width) or not is_finite(start_y) or not is_finite(end_y):
        return result
    var polygon = segment[11]
    if not polygon is Array or polygon.size() < 3:
        return result
    var tangent := delta / length
    var right := Vector2(-tangent.y, tangent.x)
    var visible_start := length
    var visible_end := 0.0
    var found_polygon_point := false
    for raw_point in polygon:
        if not raw_point is Array or raw_point.size() < 3:
            continue
        var point := Vector2(float(raw_point[0]), float(raw_point[2]))
        if not is_finite(point.x) or not is_finite(point.y):
            continue
        var station := clampf((point - a).dot(tangent), 0.0, length)
        visible_start = minf(visible_start, station)
        visible_end = maxf(visible_end, station)
        found_polygon_point = true
    if not found_polygon_point or visible_end - visible_start < 0.04:
        return result

    var span := visible_end - visible_start
    var steps := maxi(1, int(ceil(span / sample_step_m)))
    var shoulder := clampf(width * 0.10, MIN_SHOULDER_M, MAX_SHOULDER_M)
    var half_width := width * 0.5
    var tile_origin := Vector2(float(tile.x) * tile_size, float(tile.y) * tile_size)
    for index in range(steps + 1):
        var alpha := float(index) / float(steps)
        var station := lerpf(visible_start, visible_end, alpha)
        var t := clampf(station / length, 0.0, 1.0)
        var center := a + tangent * station
        var deck_y := lerpf(start_y, end_y, t)
        var section := {"station": station, "center": center - tile_origin, "deck_y": deck_y,
            "right_axis": right, "half_width": half_width, "shoulder_width": shoulder}
        var left := _side_profile(center, deck_y, right, -1.0, half_width, shoulder, tile_origin, height_sampler)
        var right_profile := _side_profile(center, deck_y, right, 1.0, half_width, shoulder, tile_origin, height_sampler)
        if not left.is_empty():
            section["left"] = left
        if not right_profile.is_empty():
            section["right"] = right_profile
        result.append(section)
    return result

func _side_profile(center: Vector2, deck_y: float, right_axis: Vector2, side: float,
        half_width: float, shoulder_width: float, tile_origin: Vector2, height_sampler: Callable) -> Dictionary:
    var shoulder_offset := half_width + shoulder_width
    var probe_offset := shoulder_offset + 6.0
    var probe_world := center + right_axis * side * probe_offset
    var probe_ground := float(height_sampler.call(probe_world.x, probe_world.y))
    if not is_finite(probe_ground):
        return {}

    # First estimate uses a near-road probe. A second sample can expand the run if
    # the outer terrain keeps climbing/falling, avoiding unrealistically steep tie-ins.
    var tie_run := clampf(3.0 + absf(probe_ground - deck_y) * 1.35, MIN_TIE_RUN_M, MAX_TIE_RUN_M)
    var tie_offset := shoulder_offset + tie_run
    var tie_world := center + right_axis * side * tie_offset
    var tie_ground := float(height_sampler.call(tie_world.x, tie_world.y))
    if not is_finite(tie_ground):
        return {}
    var required_run := clampf(3.0 + absf(tie_ground - deck_y) * 1.35, MIN_TIE_RUN_M, MAX_TIE_RUN_M)
    if required_run > tie_run + 0.25:
        tie_run = required_run
        tie_offset = shoulder_offset + tie_run
        tie_world = center + right_axis * side * tie_offset
        tie_ground = float(height_sampler.call(tie_world.x, tie_world.y))
        if not is_finite(tie_ground):
            return {}

    var delta_y := tie_ground - deck_y
    var kind := "blend"
    if delta_y > 0.25:
        kind = "cut"
    elif delta_y < -0.25:
        kind = "fill"
    var edge_world := center + right_axis * side * half_width
    var shoulder_world := center + right_axis * side * shoulder_offset
    var profile := {
        "kind": kind,
        "delta_y": delta_y,
        "tie_run_m": tie_run,
        "edge": Vector3(edge_world.x - tile_origin.x, deck_y - 0.010, edge_world.y - tile_origin.y),
        "shoulder": Vector3(shoulder_world.x - tile_origin.x, deck_y - 0.035, shoulder_world.y - tile_origin.y),
        "tie": Vector3(tie_world.x - tile_origin.x, tie_ground + 0.018, tie_world.y - tile_origin.y),
    }
    if kind == "cut" and delta_y >= CUT_DITCH_THRESHOLD_M:
        var ditch_offset := shoulder_offset + minf(DITCH_RUN_M, tie_run * 0.35)
        var ditch_world := center + right_axis * side * ditch_offset
        profile["ditch"] = Vector3(ditch_world.x - tile_origin.x, deck_y - DITCH_DEPTH_M, ditch_world.y - tile_origin.y)

    # Deep cuts and fills are not rendered as one implausible uninterrupted plane.
    # A deterministic bench breaks the slope only where the vertical delta and
    # available run are large enough. Cut benches preserve ditch clearance.
    var threshold := CUT_BENCH_THRESHOLD_M if kind == "cut" else FILL_BENCH_THRESHOLD_M
    var ditch_clearance := DITCH_RUN_M if kind == "cut" and profile.has("ditch") else 0.0
    var minimum_bench_run := ditch_clearance + BENCH_WIDTH_M + BENCH_MIN_CLEAR_M * 2.0
    if kind in ["cut", "fill"] and absf(delta_y) >= threshold and tie_run >= minimum_bench_run:
        var bench_inner_run := maxf(ditch_clearance + BENCH_MIN_CLEAR_M, tie_run * 0.46)
        var bench_outer_run := minf(tie_run - BENCH_MIN_CLEAR_M, bench_inner_run + BENCH_WIDTH_M)
        if bench_outer_run - bench_inner_run >= 0.75:
            var bench_center_run := (bench_inner_run + bench_outer_run) * 0.5
            var bench_y := deck_y + delta_y * clampf(bench_center_run / tie_run, 0.0, 1.0)
            var bench_inner_world := center + right_axis * side * (shoulder_offset + bench_inner_run)
            var bench_outer_world := center + right_axis * side * (shoulder_offset + bench_outer_run)
            profile["bench_inner"] = Vector3(bench_inner_world.x - tile_origin.x, bench_y + 0.018, bench_inner_world.y - tile_origin.y)
            profile["bench_outer"] = Vector3(bench_outer_world.x - tile_origin.x, bench_y + 0.018, bench_outer_world.y - tile_origin.y)
    return profile

func _append_segment_geometry(sections: Array[Dictionary], vertices: PackedVector3Array,
        normals: PackedVector3Array, colors: PackedColorArray, indices: PackedInt32Array,
        collision_faces: PackedVector3Array) -> void:
    for index in range(sections.size() - 1):
        var current: Dictionary = sections[index]
        var following: Dictionary = sections[index + 1]
        for side_name in ["left", "right"]:
            if not current.has(side_name) or not following.has(side_name):
                continue
            var a: Dictionary = current[side_name]
            var b: Dictionary = following[side_name]
            _append_quad(a.edge, a.shoulder, b.shoulder, b.edge, Color(0.26, 0.25, 0.22, 1.0), vertices, normals, colors, indices, collision_faces)
            var kind := str(a.get("kind", "blend")) if str(a.get("kind", "blend")) == str(b.get("kind", "blend")) else "blend"
            var earth_color := Color(0.32, 0.30, 0.20, 1.0)
            if kind == "cut":
                earth_color = Color(0.34, 0.25, 0.16, 1.0)
            elif kind == "fill":
                earth_color = Color(0.28, 0.32, 0.19, 1.0)

            var slope_a: Vector3 = a.shoulder
            var slope_b: Vector3 = b.shoulder
            if a.has("ditch") and b.has("ditch"):
                _append_quad(a.shoulder, a.ditch, b.ditch, b.shoulder, Color(0.22, 0.19, 0.14, 1.0), vertices, normals, colors, indices, collision_faces)
                slope_a = a.ditch
                slope_b = b.ditch

            if a.has("bench_inner") and a.has("bench_outer") and b.has("bench_inner") and b.has("bench_outer"):
                _append_quad(slope_a, a.bench_inner, b.bench_inner, slope_b, earth_color, vertices, normals, colors, indices, collision_faces)
                var bench_color := Color(0.30, 0.27, 0.18, 1.0) if kind == "cut" else Color(0.27, 0.34, 0.19, 1.0)
                _append_quad(a.bench_inner, a.bench_outer, b.bench_outer, b.bench_inner, bench_color, vertices, normals, colors, indices, collision_faces)
                _append_quad(a.bench_outer, a.tie, b.tie, b.bench_outer, earth_color, vertices, normals, colors, indices, collision_faces)
            else:
                _append_quad(slope_a, a.tie, b.tie, slope_b, earth_color, vertices, normals, colors, indices, collision_faces)

func _append_quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, color: Color,
        vertices: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray,
        indices: PackedInt32Array, collision_faces: PackedVector3Array) -> void:
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
    collision_faces.append_array(PackedVector3Array([a, b, c, a, c, d]))

func _earth_material() -> StandardMaterial3D:
    if _material != null:
        return _material
    _material = StandardMaterial3D.new()
    _material.vertex_color_use_as_albedo = true
    _material.roughness = 0.96
    _material.metallic = 0.0
    _material.cull_mode = BaseMaterial3D.CULL_DISABLED
    return _material
