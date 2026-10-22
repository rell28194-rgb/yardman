extends Node
class_name YardmanNearFieldBuiltEnvironment

# Presentation-only detail around the player. The registered building wall mesh,
# compiled road centreline/width and terrain height remain authoritative; this
# runtime never edits those source geometries or creates gameplay collision.
const DETAIL_DISTANCE_M := 112.0
const DETAIL_FADE_MARGIN_M := 18.0
const ACTIVE_RADIUS_M := 230.0
const ROAD_SEARCH_M := 36.0
const MAX_DETAILS_PER_CELL := 72
const MAX_FACADES_PER_CELL := 18
const GROUPS := ["masonry", "metal", "post", "drain"]

var _buildings
var _roads
var _terrain
var _refresh_clock := 0.0
var _last_active_cell := Vector2i(999999, 999999)
var _last_quality := ""
var _materials: Dictionary = {}

func _ready() -> void:
    call_deferred("_bind_sources")

func _process(delta: float) -> void:
    _refresh_clock += delta
    if _refresh_clock < 0.25:
        return
    _refresh_clock = 0.0
    if _buildings == null or not is_instance_valid(_buildings) or _roads == null or not is_instance_valid(_roads):
        _bind_sources()
        return
    var cell_size := float(_buildings.cell_size)
    if cell_size <= 0.0:
        return
    var world_position: Vector2 = _buildings._world_position
    var active_cell := Vector2i(floori(world_position.x / cell_size), floori(world_position.y / cell_size))
    var quality := str(_buildings.quality)
    if active_cell != _last_active_cell or quality != _last_quality:
        _last_active_cell = active_cell
        _last_quality = quality
        _refresh_near_cells(true)

func _exit_tree() -> void:
    if _buildings != null and is_instance_valid(_buildings):
        if _buildings.cell_ready.is_connected(_on_cell_ready):
            _buildings.cell_ready.disconnect(_on_cell_ready)
    if _roads != null and is_instance_valid(_roads):
        if _roads.tile_ready.is_connected(_on_road_tile_ready):
            _roads.tile_ready.disconnect(_on_road_tile_ready)

func _bind_sources() -> void:
    var root := get_parent()
    if root == null:
        return
    _buildings = root.get_node_or_null("JamaicaBuildingStreamer")
    _roads = root.get_node_or_null("JamaicaRoadStreamer")
    _terrain = root.get_node_or_null("JamaicaTerrainStreamer")
    if _buildings == null or _roads == null:
        return
    if not _buildings.cell_ready.is_connected(_on_cell_ready):
        _buildings.cell_ready.connect(_on_cell_ready)
    if not _roads.tile_ready.is_connected(_on_road_tile_ready):
        _roads.tile_ready.connect(_on_road_tile_ready)
    _last_active_cell = Vector2i(999999, 999999)
    _last_quality = ""
    _refresh_near_cells(true)

func _on_cell_ready(cell: Vector2i, _building_count: int) -> void:
    if _cell_near_active(cell):
        _decorate_cell(cell, true)

func _on_road_tile_ready(_tile: Vector2i) -> void:
    # A building cell can finish before the road index for its surrounding tile.
    # Retrying only the active near-field keeps the contract deterministic and
    # avoids persistent duplicate source data.
    _refresh_near_cells(true)

func _refresh_near_cells(force: bool) -> void:
    if _buildings == null or not is_instance_valid(_buildings):
        return
    for key: Variant in _buildings._loaded.keys():
        var cell := _cell_from_key(str(key))
        var entry: Dictionary = _buildings._loaded[key]
        var cell_root: Node3D = entry.get("root") as Node3D
        if cell_root == null:
            continue
        if _cell_near_active(cell):
            _decorate_cell(cell, force)
        else:
            var old := cell_root.get_node_or_null("NearFieldBuiltEnvironment")
            if old != null:
                old.free()

func _cell_near_active(cell: Vector2i) -> bool:
    if _buildings == null:
        return false
    var size := float(_buildings.cell_size)
    var center := (Vector2(cell) + Vector2.ONE * 0.5) * size
    return center.distance_to(_buildings._world_position) <= ACTIVE_RADIUS_M + size * 0.72

static func _cell_from_key(key: String) -> Vector2i:
    var pieces := key.split(":")
    if pieces.size() != 2:
        return Vector2i(999999, 999999)
    return Vector2i(int(pieces[0]), int(pieces[1]))

func _facade_budget() -> int:
    match str(_buildings.quality):
        "Performance":
            return 6
        "Balanced":
            return 11
        "Quality":
            return 15
        "Ultra":
            return MAX_FACADES_PER_CELL
        _:
            return 12

func _decorate_cell(cell: Vector2i, force: bool) -> void:
    var key := "%d:%d" % [cell.x, cell.y]
    if not _buildings._loaded.has(key):
        return
    var entry: Dictionary = _buildings._loaded[key]
    var cell_root: Node3D = entry.get("root") as Node3D
    if cell_root == null:
        return
    var existing := cell_root.get_node_or_null("NearFieldBuiltEnvironment")
    if existing != null:
        if not force:
            return
        existing.free()
    var walls := cell_root.get_node_or_null("Walls") as MeshInstance3D
    if walls == null or walls.mesh == null or walls.mesh.get_surface_count() != 1:
        return
    var arrays: Array = walls.mesh.surface_get_arrays(0)
    var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
    var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
    if vertices.size() < 4 or vertices.size() % 4 != 0:
        return
    var cell_origin := Vector2(float(cell.x) * float(_buildings.cell_size), float(cell.y) * float(_buildings.cell_size))
    var plans: Array[Dictionary] = []
    var occupied: Dictionary = {}
    var accepted_facades := 0
    var facade_limit := _facade_budget()
    for offset in range(0, vertices.size(), 4):
        if accepted_facades >= facade_limit or plans.size() >= MAX_DETAILS_PER_CELL:
            break
        var edge := _edge_from_wall(vertices, normals, offset)
        if edge.is_empty():
            continue
        var world_mid := cell_origin + Vector2(edge.mid.x, edge.mid.z)
        var occupancy := Vector2i(floori(world_mid.x / 9.0), floori(world_mid.y / 9.0))
        if occupied.has(occupancy):
            continue
        var candidates: Dictionary = _roads._nearby_surface_segments(world_mid.x, world_mid.y, ROAD_SEARCH_M)
        var road := _nearest_road(world_mid, candidates.values())
        if road.is_empty():
            continue
        var seed := ("%d:%d:%d" % [cell.x, cell.y, offset]).hash() & 0x7fffffff
        var facade_plans := _plan_front_edge(edge, road, cell_origin, seed)
        if facade_plans.is_empty():
            continue
        occupied[occupancy] = true
        accepted_facades += 1
        for plan: Dictionary in facade_plans:
            if plans.size() >= MAX_DETAILS_PER_CELL:
                break
            if _resolve_ground(plan):
                plans.append(plan)
    if plans.is_empty():
        return
    _attach_plan(cell_root, plans, accepted_facades)

func _resolve_ground(plan: Dictionary) -> bool:
    if not bool(plan.get("grounded", false)):
        return true
    if _terrain == null or not is_instance_valid(_terrain):
        return false
    var canonical: Vector2 = plan.get("canonical", Vector2(INF, INF))
    if not canonical.is_finite():
        return false
    var height := float(_terrain.height_at(canonical.x, canonical.y))
    if not is_finite(height) or height < -50.0:
        return false
    var pose: Transform3D = plan.transform
    pose.origin.y = height + float(plan.get("ground_offset", 0.0))
    plan.transform = pose
    return true

func _attach_plan(cell_root: Node3D, plans: Array[Dictionary], accepted_facades: int) -> void:
    var root := Node3D.new()
    root.name = "NearFieldBuiltEnvironment"
    root.set_meta("presentation_inference", true)
    root.set_meta("source_contract", "registered building walls + compiled road centreline/width + registered terrain height")
    root.set_meta("collision", false)
    root.set_meta("facade_count", accepted_facades)
    root.set_meta("detail_count", plans.size())
    var by_group: Dictionary = {}
    for group: String in GROUPS:
        by_group[group] = []
    for plan: Dictionary in plans:
        var group := str(plan.get("group", ""))
        if by_group.has(group):
            by_group[group].append(plan)
    for group: String in GROUPS:
        var entries: Array = by_group[group]
        if entries.is_empty():
            continue
        var multi := MultiMesh.new()
        multi.transform_format = MultiMesh.TRANSFORM_3D
        multi.use_colors = true
        var mesh := BoxMesh.new()
        mesh.size = Vector3.ONE
        mesh.material = _material(group)
        multi.mesh = mesh
        multi.instance_count = entries.size()
        for index in range(entries.size()):
            var plan: Dictionary = entries[index]
            multi.set_instance_transform(index, plan.transform)
            multi.set_instance_color(index, plan.get("color", Color.WHITE))
        var instance := MultiMeshInstance3D.new()
        instance.name = "BuiltDetail_%s" % group.capitalize()
        instance.multimesh = multi
        instance.visibility_range_end = DETAIL_DISTANCE_M
        instance.visibility_range_end_margin = DETAIL_FADE_MARGIN_M
        instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        instance.set_meta("presentation_inference", true)
        root.add_child(instance)
    cell_root.add_child(root)

func _material(group: String) -> StandardMaterial3D:
    if _materials.has(group):
        return _materials[group]
    var material := StandardMaterial3D.new()
    material.vertex_color_use_as_albedo = true
    material.roughness = 0.82
    match group:
        "metal":
            material.metallic = 0.28
            material.roughness = 0.48
        "post":
            material.roughness = 0.92
        "drain":
            material.roughness = 0.96
        _:
            material.roughness = 0.86
    _materials[group] = material
    return material

static func _edge_from_wall(vertices: PackedVector3Array, normals: PackedVector3Array, offset: int) -> Dictionary:
    if offset < 0 or offset + 3 >= vertices.size():
        return {}
    var a := vertices[offset]
    var top_a := vertices[offset + 1]
    var b := vertices[offset + 2]
    var top_b := vertices[offset + 3]
    if not a.is_finite() or not top_a.is_finite() or not b.is_finite() or not top_b.is_finite():
        return {}
    var span := Vector2(b.x - a.x, b.z - a.z)
    var length_m := span.length()
    var base_y := (a.y + b.y) * 0.5
    var top_y := (top_a.y + top_b.y) * 0.5
    var height_m := top_y - base_y
    if length_m < 2.8 or length_m > 28.0 or height_m < 2.25 or height_m > 8.2:
        return {}
    var normal := normals[offset] if normals.size() > offset else Vector3(span.y, 0.0, -span.x).normalized()
    normal.y = 0.0
    if normal.length_squared() < 0.5:
        return {}
    normal = normal.normalized()
    return {"a": a, "b": b, "mid": (a + b) * 0.5, "normal": normal,
        "length_m": length_m, "height_m": height_m, "base_y": base_y}

static func _nearest_road(point: Vector2, records: Array) -> Dictionary:
    var best: Dictionary = {}
    var best_squared := INF
    for candidate: Variant in records:
        if not candidate is Dictionary:
            continue
        var record: Dictionary = candidate
        var a: Vector2 = record.get("a", Vector2(INF, INF))
        var b: Vector2 = record.get("b", Vector2(INF, INF))
        if not a.is_finite() or not b.is_finite():
            continue
        var delta := b - a
        var length_squared := delta.length_squared()
        if length_squared < 0.001:
            continue
        var fraction := clampf((point - a).dot(delta) / length_squared, 0.0, 1.0)
        var nearest := a + delta * fraction
        var distance_squared := point.distance_squared_to(nearest)
        if distance_squared >= best_squared:
            continue
        var width_m := maxf(1.0, float(record.get("width_m", record.get("width", 5.5))))
        best_squared = distance_squared
        best = record.duplicate()
        best["point"] = nearest
        best["distance_m"] = sqrt(distance_squared)
        best["width_m"] = width_m
        best["tangent"] = delta.normalized()
    return best

static func _plan_front_edge(edge: Dictionary, road: Dictionary, cell_origin: Vector2, seed: int) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    if edge.is_empty() or road.is_empty():
        return result
    var mid: Vector3 = edge.mid
    var world_mid := cell_origin + Vector2(mid.x, mid.z)
    var road_point: Vector2 = road.get("point", Vector2(INF, INF))
    if not road_point.is_finite():
        return result
    var to_road := road_point - world_mid
    var distance_m := to_road.length()
    if distance_m < 0.1 or distance_m > ROAD_SEARCH_M:
        return result
    var road_width := maxf(1.0, float(road.get("width_m", 5.5)))
    var clearance := distance_m - road_width * 0.5
    if clearance < 0.75 or clearance > 28.0:
        return result
    var outward3: Vector3 = edge.normal
    var outward2 := Vector2(outward3.x, outward3.z).normalized()
    if outward2.dot(to_road / distance_m) < 0.18:
        return result
    var tangent3 := Vector3.UP.cross(outward3).normalized()
    if tangent3.length_squared() < 0.5:
        return result
    var length_m := float(edge.length_m)
    var height_m := float(edge.height_m)
    var base_y := float(edge.base_y)
    var variation := float(seed % 9) / 90.0
    var plaster := Color(0.72 + variation, 0.68 + variation * 0.7, 0.57 + variation * 0.45)
    var metal := Color(0.45 + variation, 0.50 + variation * 0.6, 0.49 + variation * 0.35)
    var dark := Color(0.13, 0.15, 0.14)
    var local_mid := Vector3(mid.x, base_y, mid.z)

    if seed % 4 != 1:
        var porch_width := minf(length_m * 0.56, 5.4)
        var porch_size := Vector3(porch_width, 0.17, 1.35)
        var porch_center := local_mid + outward3 * (porch_size.z * 0.5 + 0.07)
        porch_center.y = base_y + porch_size.y * 0.5 + 0.02
        result.append(_box_plan("masonry", porch_center, tangent3, outward3, porch_size, plaster))

    if length_m >= 4.2 and seed % 3 != 0:
        var awning_size := Vector3(minf(length_m * 0.68, 6.4), 0.09, 1.55)
        var awning_center := local_mid + outward3 * (awning_size.z * 0.5 + 0.05)
        awning_center.y = base_y + clampf(height_m * 0.72, 2.25, 2.75)
        result.append(_box_plan("metal", awning_center, tangent3, outward3, awning_size, metal))

    if clearance >= 5.5:
        var boundary_distance := clampf(clearance * 0.46, 2.1, 4.8)
        var boundary_local := Vector2(mid.x + outward3.x * boundary_distance, mid.z + outward3.z * boundary_distance)
        var boundary_world := cell_origin + boundary_local
        if seed % 2 == 0:
            var wall_size := Vector3(minf(length_m * 0.72, 6.2), 0.66, 0.16)
            var wall_center := Vector3(boundary_local.x, 0.0, boundary_local.y)
            result.append(_box_plan("masonry", wall_center, tangent3, outward3, wall_size,
                Color(plaster.r * 0.88, plaster.g * 0.87, plaster.b * 0.84), true, boundary_world, wall_size.y * 0.5))
        else:
            var post_span := minf(length_m * 0.58, 4.8)
            for fraction in [-0.5, 0.0, 0.5]:
                var post_local := boundary_local + Vector2(tangent3.x, tangent3.z) * post_span * float(fraction)
                var post_world := cell_origin + post_local
                var post_size := Vector3(0.11, 1.15, 0.11)
                result.append(_box_plan("post", Vector3(post_local.x, 0.0, post_local.y), tangent3, outward3,
                    post_size, Color(0.44, 0.39, 0.31), true, post_world, post_size.y * 0.5))
            var rail_size := Vector3(post_span, 0.08, 0.08)
            result.append(_box_plan("metal", Vector3(boundary_local.x, 0.0, boundary_local.y), tangent3, outward3,
                rail_size, metal, true, boundary_world, 0.78))

    var flags := int(road.get("flags", 0))
    var road_tangent2: Vector2 = road.get("tangent", Vector2.RIGHT)
    if road_tangent2.length_squared() > 0.5:
        road_tangent2 = road_tangent2.normalized()
        var toward_facade := (world_mid - road_point).normalized()
        if (flags & 8) == 0 and clearance < 20.0 and seed % 3 == 0:
            var drain_world := road_point + toward_facade * (road_width * 0.5 + 0.62)
            var drain_local := drain_world - cell_origin
            var road_tangent3 := Vector3(road_tangent2.x, 0.0, road_tangent2.y)
            var road_side3 := road_tangent3.cross(Vector3.UP).normalized()
            var drain_size := Vector3(clampf(length_m * 0.85, 3.5, 8.0), 0.06, 0.34)
            result.append(_box_plan("drain", Vector3(drain_local.x, 0.0, drain_local.y), road_tangent3, road_side3,
                drain_size, dark, true, drain_world, 0.025))
        if clearance >= 4.0 and clearance < 24.0 and seed % 5 == 0:
            var pole_world := road_point + toward_facade * (road_width * 0.5 + 2.15)
            var pole_local := pole_world - cell_origin
            var pole_size := Vector3(0.16, 6.4, 0.16)
            result.append(_box_plan("post", Vector3(pole_local.x, 0.0, pole_local.y), Vector3.RIGHT, Vector3.FORWARD,
                pole_size, Color(0.38, 0.35, 0.30), true, pole_world, pole_size.y * 0.5))
            var cross_axis := Vector3(-road_tangent2.y, 0.0, road_tangent2.x)
            var cross_z := cross_axis.cross(Vector3.UP).normalized()
            var arm_size := Vector3(1.18, 0.10, 0.10)
            result.append(_box_plan("metal", Vector3(pole_local.x, 0.0, pole_local.y), cross_axis, cross_z,
                arm_size, Color(0.34, 0.35, 0.33), true, pole_world, 6.05))
    return result

static func _box_plan(group: String, center: Vector3, x_axis: Vector3, z_axis: Vector3,
        size: Vector3, color: Color, grounded := false, canonical := Vector2.ZERO, ground_offset := 0.0) -> Dictionary:
    var x := x_axis.normalized()
    var z := z_axis.normalized()
    if x.length_squared() < 0.5 or z.length_squared() < 0.5:
        return {}
    if x.cross(Vector3.UP).dot(z) < 0.0:
        z = -z
    var basis := Basis(x, Vector3.UP, z) * Basis.from_scale(size)
    return {"group": group, "transform": Transform3D(basis, center), "color": color,
        "grounded": grounded, "canonical": canonical, "ground_offset": ground_offset}
