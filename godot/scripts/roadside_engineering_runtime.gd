extends Node

# Adds visual-only engineering cues where Jamaica's road deck and surrounding DEM
# strongly imply human intervention that the source map does not explicitly tag.
# This never changes road routing or claims a surveyed structure. Explicit OSM
# guardrails/retaining walls remain higher-authority layers. DEM-only cut faces are
# delegated to the soft road-earthworks system instead of inventing hard walls.
const FLAG_BRIDGE := 2
const FLAG_TUNNEL := 4
const SAMPLE_STEP_M := 18.0
const MIN_ENGINEERED_WIDTH_M := 4.2
const EARTHWORK_CUT_THRESHOLD_M := 2.4
const DEEP_DROP_THRESHOLD_M := 1.8
const RAIL_HEIGHT_M := 0.72
const MAPPED_GUARDRAIL_SUPPRESSION_RADIUS_M := 3.0
const VISIBILITY_RANGE_M := 1200.0

var _roads: Node
var _terrain: Node
var _connected := false
var _segments_by_tile: Dictionary = {}
# Geometry is stable for the lifetime of a loaded road tile. Cache the compact
# result after the first terrain-ready build so terrain collision/visual residency
# can cycle without repeating DEM sampling or retaining duplicate road payloads.
var _geometry_by_tile: Dictionary = {}
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
    _geometry_by_tile.erase(tile)
    _segments_by_tile[tile] = segments.duplicate(false)
    _try_build(tile)

func _on_road_tile_removed(tile: Vector2i) -> void:
    _segments_by_tile.erase(tile)
    _geometry_by_tile.erase(tile)

func _on_terrain_tile(tile: Vector2i) -> void:
    _try_build(tile)

func _on_terrain_tile_removed(tile: Vector2i) -> void:
    var root := _road_tile_root(tile)
    if root == null:
        return
    var existing := root.get_node_or_null("RoadsideEngineeringProxy")
    if existing != null:
        root.remove_child(existing)
        existing.queue_free()

func _road_tile_root(tile: Vector2i) -> Node3D:
    if _roads == null:
        return null
    return _roads._loaded.get(_roads._tile_key(tile.x, tile.y)) as Node3D

func _try_build(tile: Vector2i) -> void:
    if _terrain == null or not _terrain.is_tile_ready(tile):
        return
    if not _geometry_by_tile.has(tile) and not _segments_by_tile.has(tile):
        return
    var root := _road_tile_root(tile)
    if root == null:
        return
    var existing := root.get_node_or_null("RoadsideEngineeringProxy")
    if existing != null:
        root.remove_child(existing)
        existing.queue_free()
    var geometry: Dictionary
    if _geometry_by_tile.has(tile):
        geometry = _geometry_by_tile[tile]
    else:
        var guardrail_query := Callable()
        var guardrails := get_node_or_null("/root/GuardRailLayer")
        if guardrails != null and guardrails.has_method("has_mapped_guardrail_near"):
            guardrail_query = Callable(guardrails, "has_mapped_guardrail_near")
        geometry = build_geometry(_segments_by_tile[tile], tile, float(_roads.tile_size), _terrain.height_at, SAMPLE_STEP_M, guardrail_query)
        _geometry_by_tile[tile] = geometry
        # The generated geometry now contains everything needed to restore this
        # visual proxy. Drop the duplicate source segment array immediately.
        _segments_by_tile.erase(tile)
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
    mesh.surface_set_material(0, _engineering_material())
    var proxy := Node3D.new()
    proxy.name = "RoadsideEngineeringProxy"
    proxy.set_meta("source", "terrain-inferred visual safety; explicit Jamaica guardrails suppress inference; cut faces delegated to road earthworks")
    proxy.set_meta("retaining_spans", int(geometry.retaining_spans))
    proxy.set_meta("earthwork_cut_spans", int(geometry.earthwork_cut_spans))
    proxy.set_meta("safety_spans", int(geometry.safety_spans))
    proxy.set_meta("mapped_safety_suppressed_spans", int(geometry.mapped_safety_suppressed_spans))
    proxy.set_meta("structural_skips", int(geometry.structural_skips))
    var instance := MeshInstance3D.new()
    instance.name = "RoadsideEngineeringMesh"
    instance.mesh = mesh
    instance.visibility_range_end = VISIBILITY_RANGE_M
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    proxy.add_child(instance)
    root.add_child(proxy)

func build_geometry(segments: Array, tile: Vector2i, tile_size: float, height_sampler: Callable,
        sample_step_m: float = SAMPLE_STEP_M, guardrail_query: Callable = Callable()) -> Dictionary:
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var colors := PackedColorArray()
    var indices := PackedInt32Array()
    var retaining_spans := 0
    var earthwork_cut_spans := 0
    var safety_spans := 0
    var mapped_safety_suppressed_spans := 0
    var structural_skips := 0
    if tile_size <= 0.0 or sample_step_m <= 0.0 or not height_sampler.is_valid():
        return {"vertices": vertices, "normals": normals, "colors": colors, "indices": indices,
            "retaining_spans": 0, "earthwork_cut_spans": 0, "safety_spans": 0,
            "mapped_safety_suppressed_spans": 0, "structural_skips": 0}
    for segment in segments:
        if not segment is Array or segment.size() < 12:
            continue
        var flags := int(segment[6])
        if flags & (FLAG_BRIDGE | FLAG_TUNNEL):
            structural_skips += 1
            continue
        if float(segment[4]) < MIN_ENGINEERED_WIDTH_M:
            continue
        var sections := sample_sections(segment, tile, tile_size, height_sampler, sample_step_m, guardrail_query)
        if sections.size() < 2:
            continue
        for index in range(sections.size() - 1):
            var a: Dictionary = sections[index]
            var b: Dictionary = sections[index + 1]
            for side_name in ["left", "right"]:
                if not a.has(side_name) or not b.has(side_name):
                    continue
                var pa: Dictionary = a[side_name]
                var pb: Dictionary = b[side_name]
                var kind := str(pa.get("kind", "none"))
                if kind != str(pb.get("kind", "none")):
                    continue
                if kind == "earthwork_cut":
                    earthwork_cut_spans += 1
                elif kind == "retaining":
                    _append_quad(pa.base, pa.top, pb.top, pb.base, Color(0.43, 0.39, 0.33, 1.0), vertices, normals, colors, indices)
                    retaining_spans += 1
                elif kind == "safety":
                    _append_quad(pa.base, pa.top, pb.top, pb.base, Color(0.48, 0.50, 0.52, 1.0), vertices, normals, colors, indices)
                    safety_spans += 1
                elif kind == "mapped_safety":
                    mapped_safety_suppressed_spans += 1
    return {"vertices": vertices, "normals": normals, "colors": colors, "indices": indices,
        "retaining_spans": retaining_spans, "earthwork_cut_spans": earthwork_cut_spans,
        "safety_spans": safety_spans, "mapped_safety_suppressed_spans": mapped_safety_suppressed_spans,
        "structural_skips": structural_skips}

func sample_sections(segment: Array, tile: Vector2i, tile_size: float, height_sampler: Callable,
        sample_step_m: float = SAMPLE_STEP_M, guardrail_query: Callable = Callable()) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    if segment.size() < 12 or tile_size <= 0.0 or sample_step_m <= 0.0 or not height_sampler.is_valid():
        return result
    var a := Vector2(float(segment[0]), float(segment[1]))
    var b := Vector2(float(segment[2]), float(segment[3]))
    var delta := b - a
    var length := delta.length()
    var width := float(segment[4])
    if length < 0.05 or width < MIN_ENGINEERED_WIDTH_M:
        return result
    var polygon = segment[11]
    if not polygon is Array or polygon.size() < 3:
        return result
    var tangent := delta / length
    var right := Vector2(-tangent.y, tangent.x)
    var visible_start := length
    var visible_end := 0.0
    for raw_point in polygon:
        if raw_point is Array and raw_point.size() >= 3:
            var point := Vector2(float(raw_point[0]), float(raw_point[2]))
            var station := clampf((point - a).dot(tangent), 0.0, length)
            visible_start = minf(visible_start, station)
            visible_end = maxf(visible_end, station)
    if visible_end - visible_start < 0.04:
        return result
    var span := visible_end - visible_start
    var steps := maxi(1, int(ceil(span / sample_step_m)))
    var half_width := width * 0.5
    var shoulder := clampf(width * 0.10, 0.65, 1.35)
    var tile_origin := Vector2(float(tile.x) * tile_size, float(tile.y) * tile_size)
    for index in range(steps + 1):
        var alpha := float(index) / float(steps)
        var station := lerpf(visible_start, visible_end, alpha)
        var t := clampf(station / length, 0.0, 1.0)
        var center := a + tangent * station
        var deck_y := lerpf(float(segment[9]), float(segment[10]), t)
        var section := {}
        section["left"] = classify_side(center, deck_y, right, -1.0, half_width, shoulder, tile_origin, height_sampler, guardrail_query)
        section["right"] = classify_side(center, deck_y, right, 1.0, half_width, shoulder, tile_origin, height_sampler, guardrail_query)
        result.append(section)
    return result

func classify_side(center: Vector2, deck_y: float, right_axis: Vector2, side: float,
        half_width: float, shoulder: float, tile_origin: Vector2, height_sampler: Callable,
        guardrail_query: Callable = Callable()) -> Dictionary:
    var probe_offset := half_width + shoulder + 6.0
    var probe_world := center + right_axis * side * probe_offset
    var terrain_y := float(height_sampler.call(probe_world.x, probe_world.y))
    if not is_finite(terrain_y):
        return {"kind": "none"}
    var delta := terrain_y - deck_y
    if delta >= EARTHWORK_CUT_THRESHOLD_M:
        return {"kind": "earthwork_cut", "terrain_delta_m": delta}
    if delta <= -DEEP_DROP_THRESHOLD_M:
        var rail_offset := half_width + 0.18
        var rail_world := center + right_axis * side * rail_offset
        if guardrail_query.is_valid() and bool(guardrail_query.call(rail_world, MAPPED_GUARDRAIL_SUPPRESSION_RADIUS_M)):
            return {"kind": "mapped_safety", "terrain_delta_m": delta, "rail_world": rail_world}
        var base_y := deck_y + 0.06
        return {"kind": "safety",
            "base": Vector3(rail_world.x - tile_origin.x, base_y, rail_world.y - tile_origin.y),
            "top": Vector3(rail_world.x - tile_origin.x, base_y + RAIL_HEIGHT_M, rail_world.y - tile_origin.y),
            "terrain_delta_m": delta}
    return {"kind": "none", "terrain_delta_m": delta}

func _append_quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, color: Color,
        vertices: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray,
        indices: PackedInt32Array) -> void:
    var normal := (b - a).cross(c - a)
    if normal.length_squared() < 0.0000001:
        return
    normal = normal.normalized()
    var base := vertices.size()
    for point in [a, b, c, d]:
        vertices.append(point)
        normals.append(normal)
        colors.append(color)
    indices.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))

func _engineering_material() -> StandardMaterial3D:
    if _material != null:
        return _material
    _material = StandardMaterial3D.new()
    _material.vertex_color_use_as_albedo = true
    _material.roughness = 0.92
    _material.metallic = 0.08
    _material.cull_mode = BaseMaterial3D.CULL_DISABLED
    return _material
