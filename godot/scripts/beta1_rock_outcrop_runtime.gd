extends Node
class_name YardmanBeta1RockOutcropRuntime

# Presentation-only reuse of two recovered CarX Highway boulder meshes. Placement
# is derived from compiled road geometry, registered terrain grade and known
# hydrology exclusions. This is not surveyed geology and never mutates terrain.
const References = preload("res://scripts/reference_assets.gd")
const ROCK_FILES := ["terrain_boulder_01.glb", "terrain_boulder_02.glb"]
const BRIDGE_FLAG := 2
const TUNNEL_FLAG := 4
const CELL_M := 256.0
const SAMPLE_RADIUS_M := 4.0
const MIN_HEIGHT_M := 5.0
const MIN_GRADE := 0.18
const MAX_GRADE := 1.25
const MIN_ROAD_CLEARANCE_M := 22.0
const MAX_ROAD_CLEARANCE_M := 48.0
const MIN_WATER_CLEARANCE_M := 10.0
const MAX_ROCKS_PER_TILE := 8
const MAX_ROCKS_PER_CELL := 2
const VISIBILITY_END_M := 190.0
const VISIBILITY_FADE_M := 32.0
const QUALITY_DENSITY := {
    "Performance": 0.24,
    "Balanced": 0.55,
    "Quality": 1.0,
    "Ultra": 1.0,
    "Custom": 0.70,
}

var roads: Node
var terrain: Node
var hydrology: Node
var _segments_by_tile: Dictionary = {}
var _meshes: Array[ArrayMesh] = []
var _bind_attempted := false

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
    if _bind_attempted:
        return
    _bind_attempted = true
    var root := get_parent()
    if root == null:
        return
    roads = root.get_node_or_null("JamaicaRoadStreamer")
    terrain = root.get_node_or_null("JamaicaTerrainStreamer")
    hydrology = root.get_node_or_null("JamaicaHydrologyRenderer")
    if roads == null or terrain == null or hydrology == null:
        await get_tree().process_frame
        roads = root.get_node_or_null("JamaicaRoadStreamer")
        terrain = root.get_node_or_null("JamaicaTerrainStreamer")
        hydrology = root.get_node_or_null("JamaicaHydrologyRenderer")
    if roads == null or terrain == null or hydrology == null:
        # Fail closed: boulders are optional presentation, not required world truth.
        return
    _load_meshes()
    if _meshes.size() != ROCK_FILES.size():
        # Public CI and private packs without this recovered batch keep the
        # existing terrain path untouched.
        return
    if not roads.tile_content_ready.is_connected(_on_road_tile_ready):
        roads.tile_content_ready.connect(_on_road_tile_ready)
    if not roads.tile_removed.is_connected(_on_road_tile_removed):
        roads.tile_removed.connect(_on_road_tile_removed)
    if not terrain.tile_ready.is_connected(_on_terrain_tile_ready):
        terrain.tile_ready.connect(_on_terrain_tile_ready)

func _load_meshes() -> void:
    if not _meshes.is_empty():
        return
    for filename: String in ROCK_FILES:
        var packed: PackedScene = References.scene(filename)
        if packed == null:
            _meshes.clear()
            return
        var mesh := _combined_mesh(packed, filename)
        if mesh == null:
            _meshes.clear()
            return
        _meshes.append(mesh)

func _combined_mesh(packed: PackedScene, filename: String) -> ArrayMesh:
    var source := packed.instantiate()
    var raw := ArrayMesh.new()
    _collect_surfaces(source, Transform3D.IDENTITY, raw)
    source.free()
    if raw.get_surface_count() == 0:
        return null
    var bounds := raw.get_aabb()
    if not bounds.position.is_finite() or not bounds.size.is_finite() \
            or bounds.size.x < 1.0 or bounds.size.y < 1.0 or bounds.size.z < 1.0 \
            or bounds.size.x > 20.0 or bounds.size.y > 20.0 or bounds.size.z > 20.0:
        return null
    # Ground the source at its recovered minimum Y while retaining exact shape.
    var center := Vector3(bounds.get_center().x, bounds.position.y, bounds.get_center().z)
    var correction := Transform3D(Basis.IDENTITY, -center)
    var baked := ArrayMesh.new()
    for surface_index in range(raw.get_surface_count()):
        var surface := SurfaceTool.new()
        surface.begin(Mesh.PRIMITIVE_TRIANGLES)
        surface.append_from(raw, surface_index, correction)
        surface.index()
        surface.commit(baked)
        baked.surface_set_material(baked.get_surface_count() - 1, raw.surface_get_material(surface_index))
    baked.set_meta("reference_asset", filename)
    baked.set_meta("source_shape_preserved", true)
    return baked

func _collect_surfaces(node: Node, parent_pose: Transform3D, output: ArrayMesh) -> void:
    var pose := parent_pose
    if node is Node3D:
        pose = parent_pose * (node as Node3D).transform
    if node is MeshInstance3D:
        var instance := node as MeshInstance3D
        if instance.mesh != null:
            for surface_index in range(instance.mesh.get_surface_count()):
                var surface := SurfaceTool.new()
                surface.begin(Mesh.PRIMITIVE_TRIANGLES)
                surface.append_from(instance.mesh, surface_index, pose)
                surface.index()
                surface.commit(output)
                output.surface_set_material(output.get_surface_count() - 1, instance.get_active_material(surface_index))
    for child: Node in node.get_children():
        _collect_surfaces(child, pose, output)

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
    var game := get_parent()
    if game != null:
        var visuals = game.get("visuals")
        if visuals != null:
            return float(QUALITY_DENSITY.get(str(visuals.get("quality")), QUALITY_DENSITY.Balanced))
    return float(QUALITY_DENSITY.Balanced)

static func _stable_fraction(seed_value: int) -> float:
    return float(posmod(seed_value, 10007)) / 10007.0

func _records(segments: Array) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    var seen: Dictionary = {}
    for raw: Variant in segments:
        if not raw is Array or raw.size() < 11:
            continue
        var segment: Array = raw
        var flags := int(segment[6])
        if (flags & (BRIDGE_FLAG | TUNNEL_FLAG)) != 0:
            continue
        var key := "%s:%s:%s:%s:%s:%s" % [str(segment[7]), str(segment[8]), str(segment[0]), str(segment[1]), str(segment[2]), str(segment[3])]
        if seen.has(key):
            continue
        seen[key] = true
        var a := Vector2(float(segment[0]), float(segment[1]))
        var b := Vector2(float(segment[2]), float(segment[3]))
        if not a.is_finite() or not b.is_finite() or a.distance_squared_to(b) < 25.0:
            continue
        result.append({"a": a, "b": b, "width": clampf(float(segment[4]), 2.5, 32.0),
            "flags": flags, "seed": key.hash() & 0x7fffffff})
    result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.seed) < int(b.seed))
    return result

func _terrain_height(point: Vector2) -> float:
    return float(terrain.height_at(point.x, point.y)) if terrain != null else NAN

func _water_distance(point: Vector2) -> float:
    if hydrology == null or not hydrology.has_method("nearest_water_distance"):
        return -INF
    return float(hydrology.nearest_water_distance(point.x, point.y, MIN_WATER_CLEARANCE_M + 4.0))

static func candidate_plan(record: Dictionary, tile: Vector2i, tile_size: float,
        density: float, terrain_sampler: Callable, water_distance_sampler: Callable) -> Dictionary:
    if record.is_empty() or not terrain_sampler.is_valid() or not water_distance_sampler.is_valid() \
            or not is_finite(tile_size) or tile_size <= 0.0:
        return {}
    var seed := int(record.get("seed", 0))
    if _stable_fraction(seed * 19 + 7) > clampf(density, 0.0, 1.0) * 0.24:
        return {}
    var a: Vector2 = record.get("a", Vector2(INF, INF))
    var b: Vector2 = record.get("b", Vector2(INF, INF))
    if not a.is_finite() or not b.is_finite():
        return {}
    var delta := b - a
    var length_m := delta.length()
    if length_m < 5.0:
        return {}
    var direction := delta / length_m
    var right := Vector2(-direction.y, direction.x)
    var fraction := 0.22 + _stable_fraction(seed * 31 + 17) * 0.56
    var side := -1.0 if (seed & 1) == 0 else 1.0
    var clearance := lerpf(MIN_ROAD_CLEARANCE_M, MAX_ROAD_CLEARANCE_M, _stable_fraction(seed * 43 + 29))
    clearance += float(record.get("width", 5.5)) * 0.5
    var point := a.lerp(b, fraction) + right * clearance * side
    if int(floor(point.x / tile_size)) != tile.x or int(floor(point.y / tile_size)) != tile.y:
        return {}
    var h := float(terrain_sampler.call(point))
    if not is_finite(h) or h < MIN_HEIGHT_M:
        return {}
    var hx0 := float(terrain_sampler.call(point - Vector2(SAMPLE_RADIUS_M, 0.0)))
    var hx1 := float(terrain_sampler.call(point + Vector2(SAMPLE_RADIUS_M, 0.0)))
    var hz0 := float(terrain_sampler.call(point - Vector2(0.0, SAMPLE_RADIUS_M)))
    var hz1 := float(terrain_sampler.call(point + Vector2(0.0, SAMPLE_RADIUS_M)))
    if not is_finite(hx0) or not is_finite(hx1) or not is_finite(hz0) or not is_finite(hz1):
        return {}
    var gx := (hx1 - hx0) / (SAMPLE_RADIUS_M * 2.0)
    var gz := (hz1 - hz0) / (SAMPLE_RADIUS_M * 2.0)
    var grade := Vector2(gx, gz).length()
    if grade < MIN_GRADE or grade > MAX_GRADE:
        return {}
    var water_distance := float(water_distance_sampler.call(point))
    if not is_finite(water_distance) or water_distance < MIN_WATER_CLEARANCE_M:
        return {}
    var normal := Vector3(-gx, 1.0, -gz).normalized()
    var align := Basis(Quaternion(Vector3.UP, normal))
    var yaw := _stable_fraction(seed * 67 + 41) * TAU
    var scale_value := 0.55 + _stable_fraction(seed * 83 + 53) * 0.30
    var basis := Basis(normal, yaw) * align
    basis = basis.scaled(Vector3.ONE * scale_value)
    return {"point": point, "height": h, "grade": grade, "normal": normal,
        "variant": posmod(seed, ROCK_FILES.size()), "scale": scale_value,
        "road_clearance_m": clearance, "water_clearance_m": water_distance,
        "basis": basis, "seed": seed}

func _build_tile(tile: Vector2i, tile_root: Node3D, segments: Array) -> void:
    var old := tile_root.get_node_or_null("Beta1RockOutcrops")
    if old != null:
        tile_root.remove_child(old)
        old.queue_free()
    if _meshes.size() != ROCK_FILES.size() or terrain == null or hydrology == null or roads == null:
        return
    var tile_origin := Vector2(float(tile.x) * float(roads.tile_size), float(tile.y) * float(roads.tile_size))
    var groups: Dictionary = {}
    var accepted := 0
    var density := _quality_density()
    var terrain_sampler := func(point: Vector2) -> float: return _terrain_height(point)
    var water_sampler := func(point: Vector2) -> float: return _water_distance(point)
    for record: Dictionary in _records(segments):
        if accepted >= MAX_ROCKS_PER_TILE:
            break
        var plan := candidate_plan(record, tile, float(roads.tile_size), density, terrain_sampler, water_sampler)
        if plan.is_empty():
            continue
        var point: Vector2 = plan.point
        var local := Vector3(point.x - tile_origin.x, float(plan.height) + 0.035, point.y - tile_origin.y)
        var cell := Vector2i(floori(local.x / CELL_M), floori(local.z / CELL_M))
        var key := "%d:%d:%d" % [cell.x, cell.y, int(plan.variant)]
        if not groups.has(key):
            groups[key] = {"cell": cell, "variant": int(plan.variant), "anchors": []}
        var anchors: Array = groups[key].anchors
        if anchors.size() >= MAX_ROCKS_PER_CELL:
            continue
        anchors.append({"transform": Transform3D(plan.basis, local), "grade": float(plan.grade),
            "road_clearance_m": float(plan.road_clearance_m), "water_clearance_m": float(plan.water_clearance_m)})
        accepted += 1
    if accepted == 0:
        return
    var root_node := Node3D.new()
    root_node.name = "Beta1RockOutcrops"
    root_node.set_meta("presentation_inference", true)
    root_node.set_meta("source_contract", "compiled ordinary roads + registered terrain grade + hydrology clearance")
    root_node.set_meta("geology_truth", false)
    root_node.set_meta("terrain_mutation", false)
    root_node.set_meta("collision", false)
    root_node.set_meta("rock_count", accepted)
    for group: Dictionary in groups.values():
        _make_cell(root_node, group)
    if root_node.get_child_count() > 0:
        tile_root.add_child(root_node)
    else:
        root_node.free()

func _make_cell(parent: Node3D, group: Dictionary) -> void:
    var anchors: Array = group.anchors
    if anchors.is_empty():
        return
    var cell: Vector2i = group.cell
    var center := Vector3((float(cell.x) + 0.5) * CELL_M, 0.0, (float(cell.y) + 0.5) * CELL_M)
    var average_y := 0.0
    for anchor: Dictionary in anchors:
        average_y += (anchor.transform as Transform3D).origin.y
    center.y = average_y / float(anchors.size())
    var multi := MultiMesh.new()
    multi.transform_format = MultiMesh.TRANSFORM_3D
    multi.mesh = _meshes[int(group.variant)]
    multi.instance_count = anchors.size()
    for index in range(anchors.size()):
        var pose: Transform3D = anchors[index].transform
        pose.origin -= center
        multi.set_instance_transform(index, pose)
    var instance := MultiMeshInstance3D.new()
    instance.name = "RecoveredBoulders_%d_%d_%d" % [cell.x, cell.y, int(group.variant)]
    instance.position = center
    instance.multimesh = multi
    instance.visibility_range_end = VISIBILITY_END_M
    instance.visibility_range_end_margin = VISIBILITY_FADE_M
    instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    instance.set_meta("reference_asset", ROCK_FILES[int(group.variant)])
    instance.set_meta("source_anchors", anchors.size())
    instance.set_meta("collision", false)
    parent.add_child(instance)

static func asset_contract() -> Dictionary:
    return {"files": ROCK_FILES.duplicate(), "presentation_inference": true, "geology_truth": false,
        "terrain_mutation": false, "collision": false, "max_per_tile": MAX_ROCKS_PER_TILE,
        "max_per_cell": MAX_ROCKS_PER_CELL, "min_grade": MIN_GRADE,
        "min_road_clearance_m": MIN_ROAD_CLEARANCE_M, "max_road_clearance_m": MAX_ROAD_CLEARANCE_M,
        "min_water_clearance_m": MIN_WATER_CLEARANCE_M, "asset_absent_fallback": true}
