extends Node
class_name YardmanNearFieldGroundcoverRuntime

# Deterministic visual roadside groundcover. This is presentation density, not
# surveyed vegetation/land-cover truth. Anchors are derived from compiled road
# geometry and registered terrain height, grouped into 256 m MultiMesh cells so
# Android pays per-cell batches rather than one node/draw setup per tuft.

const FOLIAGE_SHADER = preload("res://shaders/foliage.gdshader")
const CELL_M := 256.0
const ANCHOR_SPACING_M := 12.0
const MAX_ANCHORS_PER_CELL := 48
const MIN_ROAD_CLEARANCE_M := 3.8
const VERGE_WIDTH_M := 8.5
const VISIBILITY_M := 165.0
const VISIBILITY_FADE_M := 32.0
const QUALITY_DENSITY := {
    "Performance": 0.38,
    "Balanced": 0.72,
    "Quality": 1.0,
    "Ultra": 1.0,
    "Custom": 0.78,
}

var roads: Node
var terrain: Node
var density_factor_override := -1.0
var cells_built := 0
var anchors_built := 0
var rejected_height := 0
var rejected_density := 0
var _segments_by_tile: Dictionary = {}
var _mesh: ArrayMesh

func _ready() -> void:
    call_deferred("_bind_streamers")

func _exit_tree() -> void:
    if roads != null:
        if roads.tile_content_ready.is_connected(_on_road_tile_ready):
            roads.tile_content_ready.disconnect(_on_road_tile_ready)
        if roads.tile_removed.is_connected(_on_road_tile_removed):
            roads.tile_removed.disconnect(_on_road_tile_removed)
    if terrain != null and terrain.tile_ready.is_connected(_on_terrain_tile_ready):
        terrain.tile_ready.disconnect(_on_terrain_tile_ready)
    _segments_by_tile.clear()

func _bind_streamers() -> void:
    roads = get_parent().get_node_or_null("JamaicaRoadStreamer")
    terrain = get_parent().get_node_or_null("JamaicaTerrainStreamer")
    if roads == null or terrain == null:
        await get_tree().process_frame
        roads = get_parent().get_node_or_null("JamaicaRoadStreamer")
        terrain = get_parent().get_node_or_null("JamaicaTerrainStreamer")
    if roads == null or terrain == null:
        push_error("Near-field groundcover could not find road/terrain streamers")
        return
    if not roads.tile_content_ready.is_connected(_on_road_tile_ready):
        roads.tile_content_ready.connect(_on_road_tile_ready)
    if not roads.tile_removed.is_connected(_on_road_tile_removed):
        roads.tile_removed.connect(_on_road_tile_removed)
    if not terrain.tile_ready.is_connected(_on_terrain_tile_ready):
        terrain.tile_ready.connect(_on_terrain_tile_ready)

func _tile_key(tile: Vector2i) -> String:
    return "%d:%d" % [tile.x, tile.y]

func _on_road_tile_ready(tile: Vector2i, tile_root: Node3D, segments: Array) -> void:
    _segments_by_tile[_tile_key(tile)] = segments.duplicate(true)
    _build_tile(tile, tile_root, segments)

func _on_road_tile_removed(tile: Vector2i) -> void:
    _segments_by_tile.erase(_tile_key(tile))

func _on_terrain_tile_ready(tile: Vector2i) -> void:
    if roads == null:
        return
    var key := _tile_key(tile)
    if not _segments_by_tile.has(key):
        return
    var tile_root = roads._loaded.get(key)
    if tile_root is Node3D:
        _build_tile(tile, tile_root, _segments_by_tile[key])

func _quality_density() -> float:
    if density_factor_override >= 0.0:
        return clampf(density_factor_override, 0.0, 1.0)
    var game := get_parent()
    if game != null:
        var visuals = game.get("visuals")
        if visuals != null:
            var quality := str(visuals.get("quality"))
            return float(QUALITY_DENSITY.get(quality, QUALITY_DENSITY.Balanced))
    return float(QUALITY_DENSITY.Balanced)

func _regional_dryness(point: Vector2) -> float:
    var south := smoothstep(-18000.0, 18000.0, point.y)
    var west := 1.0 - smoothstep(-90000.0, 15000.0, point.x)
    return clampf(0.12 + south * 0.30 + west * south * 0.18, 0.1, 0.6)

func _stable_fraction(seed_value: int) -> float:
    return float(posmod(seed_value, 10007)) / 10007.0

func _records(segments: Array) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    var seen: Dictionary = {}
    for raw in segments:
        if not raw is Array or raw.size() < 11:
            continue
        var segment: Array = raw
        var key := "%s:%s:%s:%s:%s:%s" % [str(segment[7]), str(segment[8]), str(segment[0]), str(segment[1]), str(segment[2]), str(segment[3])]
        if seen.has(key):
            continue
        seen[key] = true
        var a := Vector2(float(segment[0]), float(segment[1]))
        var b := Vector2(float(segment[2]), float(segment[3]))
        if a.distance_squared_to(b) < 1.0:
            continue
        result.append({
            "a": a,
            "b": b,
            "width": clampf(float(segment[4]), 2.5, 32.0),
            "seed": key.hash() & 0x7fffffff,
        })
    result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.seed) < int(b.seed))
    return result

func _build_tile(tile: Vector2i, tile_root: Node3D, segments: Array) -> void:
    var old := tile_root.get_node_or_null("NearFieldGroundcover")
    if old != null:
        tile_root.remove_child(old)
        old.queue_free()
    if terrain == null or roads == null:
        return
    var groups: Dictionary = {}
    var tile_origin := Vector2(float(tile.x) * float(roads.tile_size), float(tile.y) * float(roads.tile_size))
    var density := _quality_density()
    var built_here := 0
    for record: Dictionary in _records(segments):
        var a: Vector2 = record.a
        var b: Vector2 = record.b
        var delta := b - a
        var length_m := delta.length()
        var direction := delta / length_m
        var right := Vector2(-direction.y, direction.x)
        var steps := maxi(1, int(ceil(length_m / ANCHOR_SPACING_M)))
        for step in range(steps):
            for side in [-1.0, 1.0]:
                var seed_value := posmod(int(record.seed) + step * 7919 + (104729 if side > 0.0 else 0), 2147483647)
                if _stable_fraction(seed_value) > density:
                    rejected_density += 1
                    continue
                var along_jitter := (_stable_fraction(seed_value * 31 + 17) - 0.5) * ANCHOR_SPACING_M * 0.55
                var station := clampf((float(step) + 0.5) * length_m / float(steps) + along_jitter, 0.5, length_m - 0.5)
                var verge_jitter := _stable_fraction(seed_value * 47 + 29)
                var offset := float(record.width) * 0.5 + MIN_ROAD_CLEARANCE_M + verge_jitter * VERGE_WIDTH_M
                var point := a + direction * station + right * offset * side
                if int(floor(point.x / float(roads.tile_size))) != tile.x or int(floor(point.y / float(roads.tile_size))) != tile.y:
                    continue
                var height := float(terrain.height_at(point.x, point.y))
                if not is_finite(height) or height < 1.25:
                    rejected_height += 1
                    continue
                var local := Vector3(point.x - tile_origin.x, height + 0.015, point.y - tile_origin.y)
                var cell := Vector2i(int(floor(local.x / CELL_M)), int(floor(local.z / CELL_M)))
                var cell_key := "%d:%d" % [cell.x, cell.y]
                if not groups.has(cell_key):
                    groups[cell_key] = {"cell": cell, "anchors": []}
                var anchors: Array = groups[cell_key].anchors
                if anchors.size() >= MAX_ANCHORS_PER_CELL:
                    continue
                var scale_value := 0.76 + _stable_fraction(seed_value * 67 + 43) * 0.68
                var yaw := _stable_fraction(seed_value * 89 + 71) * TAU
                anchors.append({
                    "transform": Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3.ONE * scale_value), local),
                    "seed": seed_value,
                    "dry": _regional_dryness(point),
                })
                built_here += 1
    if built_here <= 0:
        return
    var root_node := Node3D.new()
    root_node.name = "NearFieldGroundcover"
    for group: Dictionary in groups.values():
        if not group.anchors.is_empty():
            _make_cell(root_node, group)
    if root_node.get_child_count() <= 0:
        root_node.queue_free()
        return
    root_node.set_meta("anchor_count", built_here)
    root_node.set_meta("density_factor", density)
    tile_root.add_child(root_node)
    cells_built += root_node.get_child_count()
    anchors_built += built_here

func _make_cell(parent: Node3D, group: Dictionary) -> void:
    if _mesh == null:
        _mesh = _make_cluster_mesh()
    var anchors: Array = group.anchors
    var cell: Vector2i = group.cell
    var center := Vector3((float(cell.x) + 0.5) * CELL_M, 0.0, (float(cell.y) + 0.5) * CELL_M)
    var average_y := 0.0
    for anchor: Dictionary in anchors:
        average_y += float(anchor.transform.origin.y)
    center.y = average_y / float(anchors.size())
    var multi := MultiMesh.new()
    multi.transform_format = MultiMesh.TRANSFORM_3D
    multi.use_custom_data = true
    multi.mesh = _mesh
    multi.instance_count = anchors.size()
    for index in range(anchors.size()):
        var anchor: Dictionary = anchors[index]
        var pose: Transform3D = anchor.transform
        pose.origin -= center
        multi.set_instance_transform(index, pose)
        var seed_value := int(anchor.seed)
        multi.set_instance_custom_data(index, Color(
            _stable_fraction(seed_value),
            _stable_fraction(seed_value * 17 + 5),
            float(anchor.dry),
            1.0))
    var instance := MultiMeshInstance3D.new()
    instance.name = "RoadGroundcover_%d_%d" % [cell.x, cell.y]
    instance.position = center
    instance.multimesh = multi
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    instance.visibility_range_end = VISIBILITY_M
    instance.visibility_range_end_margin = VISIBILITY_FADE_M
    instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
    instance.set_meta("near_field_groundcover", true)
    instance.set_meta("source_anchors", anchors.size())
    parent.add_child(instance)

func _triangle(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, color: Color) -> void:
    surface.set_color(color)
    surface.add_vertex(a)
    surface.set_color(color)
    surface.add_vertex(b)
    surface.set_color(color)
    surface.add_vertex(c)

func _make_cluster_mesh() -> ArrayMesh:
    var surface := SurfaceTool.new()
    surface.begin(Mesh.PRIMITIVE_TRIANGLES)
    # Six overlapping mini-clumps make each 12 m anchor read as a patch rather
    # than one isolated tuft. They remain one mesh/one MultiMesh material batch.
    for clump in range(6):
        var clump_angle := float(clump) * 2.39996323
        var clump_radius := 0.28 + float(clump % 3) * 0.34
        var base := Vector3(cos(clump_angle) * clump_radius, 0.0, sin(clump_angle) * clump_radius)
        for blade in range(7):
            var angle := clump_angle + float(blade) * TAU / 7.0
            var side := Vector3(cos(angle), 0.0, sin(angle))
            var start := base + Vector3(sin(float(blade) * 1.7) * 0.12, 0.01, cos(float(blade) * 2.1) * 0.12)
            var middle := start + Vector3.UP * (0.22 + float((blade + clump) % 3) * 0.055)
            var tip := start + Vector3.UP * (0.43 + float((blade + clump) % 5) * 0.055) + side * 0.19
            var shade := 0.72 + float((blade * 3 + clump) % 7) * 0.045
            _triangle(surface, start - side * 0.026, start + side * 0.026, middle, Color(shade, shade * 1.02, shade * 0.72, 0.0))
            _triangle(surface, start + side * 0.026, tip, middle, Color(minf(1.0, shade * 1.14), 1.0, shade * 0.86, 1.0))
    # A few broadleaf weed shapes break the pure lawn silhouette with no extra
    # material surface or draw batch.
    for weed in range(4):
        var angle := float(weed) * TAU / 4.0 + 0.47
        var root := Vector3(cos(angle) * 0.42, 0.018, sin(angle) * 0.42)
        var outward := Vector3(cos(angle), 0.0, sin(angle))
        var lateral := Vector3(-outward.z, 0.0, outward.x)
        var tip := root + outward * 0.34 + Vector3.UP * (0.22 + float(weed % 2) * 0.08)
        var left := root + outward * 0.14 + lateral * 0.13 + Vector3.UP * 0.09
        var right_leaf := root + outward * 0.14 - lateral * 0.13 + Vector3.UP * 0.09
        _triangle(surface, root, left, tip, Color(0.76, 0.94, 0.69, 0.45))
        _triangle(surface, root, tip, right_leaf, Color(0.68, 0.88, 0.61, 0.45))
    surface.generate_normals()
    var mesh := surface.commit()
    var material := ShaderMaterial.new()
    material.shader = FOLIAGE_SHADER
    material.set_shader_parameter("tint", Color(0.31, 0.48, 0.12))
    material.set_shader_parameter("wind_strength", 0.085)
    mesh.surface_set_material(0, material)
    return mesh
