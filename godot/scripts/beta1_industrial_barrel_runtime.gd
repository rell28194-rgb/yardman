extends Node
class_name YardmanBeta1IndustrialBarrelRuntime

# Presentation-only private-pack reuse. Source building type and compiled road
# access determine where a barrel may appear; residential/commercial buildings
# are never decorated by this layer and source geometry is never edited.
const References = preload("res://scripts/reference_assets.gd")
const BuiltEnvironment = preload("res://scripts/near_field_built_environment_runtime.gd")
const BARREL_FILE := "settlement_industrial_barrel.glb"
const ACTIVE_RADIUS_M := 190.0
const VISIBILITY_END_M := 96.0
const VISIBILITY_FADE_M := 18.0
const ROAD_SEARCH_M := 34.0
const MAX_BARRELS_PER_CELL := 6
const MIN_CLEARANCE_FROM_PAVEMENT_M := 1.6
const MAX_CLEARANCE_FROM_PAVEMENT_M := 16.0
const BRIDGE_FLAG := 2
const TUNNEL_FLAG := 4

var _buildings
var _roads
var _terrain
var _barrel_mesh: ArrayMesh
var _records_cache: Dictionary = {}
var _clock := 0.0
var _last_cell := Vector2i(999999, 999999)

func _ready() -> void:
    call_deferred("_bind_sources")

func _process(delta: float) -> void:
    _clock += delta
    if _clock < 0.35:
        return
    _clock = 0.0
    if _buildings == null or not is_instance_valid(_buildings) or _roads == null or not is_instance_valid(_roads):
        _bind_sources()
        return
    var size := float(_buildings.cell_size)
    if size <= 0.0:
        return
    var active := Vector2i(floori(_buildings._world_position.x / size), floori(_buildings._world_position.y / size))
    if active != _last_cell:
        _last_cell = active
        _refresh_near_cells(true)

func _exit_tree() -> void:
    if _buildings != null and is_instance_valid(_buildings):
        if _buildings.cell_ready.is_connected(_on_cell_ready):
            _buildings.cell_ready.disconnect(_on_cell_ready)
        if _buildings.cell_removed.is_connected(_on_cell_removed):
            _buildings.cell_removed.disconnect(_on_cell_removed)
    if _roads != null and is_instance_valid(_roads) and _roads.tile_ready.is_connected(_on_road_tile_ready):
        _roads.tile_ready.disconnect(_on_road_tile_ready)
    _records_cache.clear()

func _bind_sources() -> void:
    var root := get_parent()
    if root == null:
        return
    _buildings = root.get_node_or_null("JamaicaBuildingStreamer")
    _roads = root.get_node_or_null("JamaicaRoadStreamer")
    _terrain = root.get_node_or_null("JamaicaTerrainStreamer")
    if _buildings == null or _roads == null or _terrain == null:
        return
    if not _buildings.cell_ready.is_connected(_on_cell_ready):
        _buildings.cell_ready.connect(_on_cell_ready)
    if not _buildings.cell_removed.is_connected(_on_cell_removed):
        _buildings.cell_removed.connect(_on_cell_removed)
    if not _roads.tile_ready.is_connected(_on_road_tile_ready):
        _roads.tile_ready.connect(_on_road_tile_ready)
    if _barrel_mesh == null:
        _barrel_mesh = _load_reference_mesh()
    _last_cell = Vector2i(999999, 999999)
    _refresh_near_cells(true)

func _load_reference_mesh() -> ArrayMesh:
    var packed: PackedScene = References.scene(BARREL_FILE)
    if packed == null:
        return null
    var source := packed.instantiate()
    var raw := ArrayMesh.new()
    _collect_surfaces(source, Transform3D.IDENTITY, raw)
    source.free()
    if raw.get_surface_count() == 0:
        return null
    var bounds := raw.get_aabb()
    if not bounds.position.is_finite() or not bounds.size.is_finite() \
            or bounds.size.x < 0.4 or bounds.size.y < 0.6 or bounds.size.z < 0.4 \
            or bounds.size.x > 2.0 or bounds.size.y > 2.0 or bounds.size.z > 2.0:
        return null
    # Preserve recovered metre scale and shape; only move the pivot to the
    # ground-centred origin so terrain grounding is deterministic.
    var center := Vector3(bounds.get_center().x, bounds.position.y, bounds.get_center().z)
    var correction := Transform3D(Basis.IDENTITY, -center)
    var grounded := ArrayMesh.new()
    for surface_index in range(raw.get_surface_count()):
        var surface := SurfaceTool.new()
        surface.begin(Mesh.PRIMITIVE_TRIANGLES)
        surface.append_from(raw, surface_index, correction)
        surface.index()
        surface.commit(grounded)
        grounded.surface_set_material(grounded.get_surface_count() - 1, raw.surface_get_material(surface_index))
    grounded.set_meta("reference_asset", BARREL_FILE)
    grounded.set_meta("source_shape_preserved", true)
    grounded.set_meta("source_scale_preserved", true)
    return grounded

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

func _on_cell_ready(cell: Vector2i, _building_count: int) -> void:
    _records_cache.erase(_cell_key(cell))
    if _cell_near_active(cell):
        _decorate_cell(cell, true)

func _on_cell_removed(cell: Vector2i) -> void:
    _records_cache.erase(_cell_key(cell))

func _on_road_tile_ready(_tile: Vector2i) -> void:
    _refresh_near_cells(true)

func _refresh_near_cells(force: bool) -> void:
    if _buildings == null or not is_instance_valid(_buildings):
        return
    for raw_key: Variant in _buildings._loaded.keys():
        var key := str(raw_key)
        var cell := _cell_from_key(key)
        var entry: Dictionary = _buildings._loaded[raw_key]
        var cell_root := entry.get("root") as Node3D
        if cell_root == null:
            continue
        if _cell_near_active(cell):
            _decorate_cell(cell, force)
        else:
            var old := cell_root.get_node_or_null("Beta1IndustrialBarrels")
            if old != null:
                old.queue_free()

func _cell_near_active(cell: Vector2i) -> bool:
    if _buildings == null:
        return false
    var size := float(_buildings.cell_size)
    var center := (Vector2(cell) + Vector2.ONE * 0.5) * size
    return center.distance_to(_buildings._world_position) <= ACTIVE_RADIUS_M + size * 0.72

func _cell_records(cell: Vector2i) -> Array:
    var key := _cell_key(cell)
    if _records_cache.has(key):
        return _records_cache[key]
    var address: Dictionary = _buildings._address(cell)
    var tile_key := _cell_key(address.tile)
    if not _buildings._tile_files.has(tile_key):
        _records_cache[key] = []
        return []
    var path := str(_buildings.data_root) + "/" + str(_buildings._tile_files[tile_key])
    var result: Dictionary = _buildings._read_cell(path, address.local)
    var records: Array = result.get("records", []) if not result.has("error") else []
    _records_cache[key] = records
    return records

func _decorate_cell(cell: Vector2i, force: bool) -> void:
    if _barrel_mesh == null or _buildings == null or _roads == null or _terrain == null:
        return
    var key := _cell_key(cell)
    if not _buildings._loaded.has(key):
        return
    var entry: Dictionary = _buildings._loaded[key]
    var cell_root := entry.get("root") as Node3D
    if cell_root == null:
        return
    var old := cell_root.get_node_or_null("Beta1IndustrialBarrels")
    if old != null:
        if not force:
            return
        old.queue_free()
    var cell_origin := Vector2(float(cell.x) * float(_buildings.cell_size), float(cell.y) * float(_buildings.cell_size))
    var plans: Array[Dictionary] = []
    for raw: Variant in _cell_records(cell):
        if plans.size() >= MAX_BARRELS_PER_CELL:
            break
        if not raw is Array:
            continue
        var record: Array = raw
        if not is_industrial_record(record):
            continue
        var plan := _plan_record(record, cell_origin)
        if not plan.is_empty() and _ground_plan(plan):
            plans.append(plan)
    if plans.is_empty():
        return
    var multi := MultiMesh.new()
    multi.transform_format = MultiMesh.TRANSFORM_3D
    multi.mesh = _barrel_mesh
    multi.instance_count = plans.size()
    for index in range(plans.size()):
        multi.set_instance_transform(index, plans[index].transform)
    var instance := MultiMeshInstance3D.new()
    instance.name = "IndustrialBarrels"
    instance.multimesh = multi
    instance.visibility_range_end = VISIBILITY_END_M
    instance.visibility_range_end_margin = VISIBILITY_FADE_M
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    instance.set_meta("reference_asset", BARREL_FILE)
    var root := Node3D.new()
    root.name = "Beta1IndustrialBarrels"
    root.set_meta("presentation_inference", true)
    root.set_meta("source_contract", "OSM industrial/warehouse building type + compiled road centreline/width + registered terrain")
    root.set_meta("collision", false)
    root.set_meta("barrel_count", plans.size())
    root.add_child(instance)
    cell_root.add_child(root)

func _plan_record(record: Array, cell_origin: Vector2) -> Dictionary:
    if not is_industrial_record(record) or record.size() < 9 or not record[5] is Array or record[5].is_empty():
        return {}
    var ring: Variant = record[5][0]
    if not ring is Array or ring.size() < 3:
        return {}
    var best: Dictionary = {}
    var best_distance := INF
    for edge_index in range(ring.size()):
        var edge := edge_from_ring(ring, edge_index)
        if edge.is_empty():
            continue
        var world_mid := cell_origin + Vector2(edge.mid.x, edge.mid.z)
        var candidates: Dictionary = _roads._nearby_surface_segments(world_mid.x, world_mid.y, ROAD_SEARCH_M)
        var road := BuiltEnvironment._nearest_road(world_mid, candidates.values())
        if road.is_empty():
            continue
        var seed := (str(record[0]) + ":" + str(edge_index)).hash() & 0x7fffffff
        var plan := plan_barrel(edge, road, cell_origin, seed)
        if plan.is_empty():
            continue
        var distance := float(plan.get("road_distance_m", INF))
        if distance < best_distance:
            best_distance = distance
            best = plan
    return best

func _ground_plan(plan: Dictionary) -> bool:
    var canonical: Vector2 = plan.get("canonical", Vector2(INF, INF))
    if not canonical.is_finite():
        return false
    var height := float(_terrain.height_at(canonical.x, canonical.y))
    if not is_finite(height) or height < -50.0:
        return false
    var pose: Transform3D = plan.get("transform", Transform3D.IDENTITY)
    pose.origin.y = height + 0.025
    plan["transform"] = pose
    return true

static func is_industrial_record(record: Array) -> bool:
    if record.size() < 9 or not record[8] is Dictionary:
        return false
    var form: Dictionary = record[8]
    if bool(form.get("building_part", false)):
        return false
    var source_type := str(form.get("building_type", "")).to_lower()
    return source_type in ["industrial", "warehouse"]

static func edge_from_ring(ring: Array, index: int) -> Dictionary:
    if ring.size() < 3 or index < 0 or index >= ring.size():
        return {}
    var a_raw: Variant = ring[index]
    var b_raw: Variant = ring[(index + 1) % ring.size()]
    if not a_raw is Array or not b_raw is Array or a_raw.size() < 3 or b_raw.size() < 3:
        return {}
    var a := Vector3(float(a_raw[0]), float(a_raw[1]), float(a_raw[2]))
    var b := Vector3(float(b_raw[0]), float(b_raw[1]), float(b_raw[2]))
    if not a.is_finite() or not b.is_finite():
        return {}
    var tangent := Vector3(b.x - a.x, 0.0, b.z - a.z)
    var length := tangent.length()
    if length < 1.2:
        return {}
    tangent /= length
    var area := 0.0
    for ring_index in range(ring.size()):
        var p: Variant = ring[ring_index]
        var q: Variant = ring[(ring_index + 1) % ring.size()]
        if p is Array and q is Array and p.size() >= 3 and q.size() >= 3:
            area += float(p[0]) * float(q[2]) - float(q[0]) * float(p[2])
    var outward := Vector3(tangent.z, 0.0, -tangent.x) * (1.0 if area > 0.0 else -1.0)
    return {"a": a, "b": b, "mid": (a + b) * 0.5, "tangent": tangent,
        "outward": outward.normalized(), "length_m": length}

static func plan_barrel(edge: Dictionary, road: Dictionary, cell_origin: Vector2, seed: int) -> Dictionary:
    if edge.is_empty() or road.is_empty():
        return {}
    var mid: Vector3 = edge.get("mid", Vector3(INF, INF, INF))
    var outward3: Vector3 = edge.get("outward", Vector3.ZERO)
    var tangent3: Vector3 = edge.get("tangent", Vector3.ZERO)
    var road_point: Vector2 = road.get("point", Vector2(INF, INF))
    if not mid.is_finite() or not road_point.is_finite() or outward3.length_squared() < 0.5 or tangent3.length_squared() < 0.5:
        return {}
    var flags := int(road.get("flags", 0))
    if (flags & (BRIDGE_FLAG | TUNNEL_FLAG)) != 0:
        return {}
    var world_mid := cell_origin + Vector2(mid.x, mid.z)
    var to_road := road_point - world_mid
    var road_distance := to_road.length()
    if road_distance < 0.1 or road_distance > ROAD_SEARCH_M:
        return {}
    var outward := Vector2(outward3.x, outward3.z).normalized()
    if outward.dot(to_road / road_distance) < 0.22:
        return {}
    var road_width := maxf(1.0, float(road.get("width_m", road.get("width", 5.5))))
    var pavement_clearance := road_distance - road_width * 0.5
    if pavement_clearance < MIN_CLEARANCE_FROM_PAVEMENT_M or pavement_clearance > MAX_CLEARANCE_FROM_PAVEMENT_M:
        return {}
    var tangent := Vector2(tangent3.x, tangent3.z).normalized()
    var edge_length := float(edge.get("length_m", 0.0))
    var side := -1.0 if (seed & 1) == 0 else 1.0
    var lateral := side * minf(edge_length * 0.22, 1.35)
    var canonical := world_mid + outward * 0.72 + tangent * lateral
    # Recheck the finished anchor against the pavement edge; the barrel may not
    # encroach on the compiled drivable surface.
    var finished_clearance := canonical.distance_to(road_point) - road_width * 0.5
    if finished_clearance < 0.85:
        return {}
    var local := canonical - cell_origin
    var yaw := float(posmod(seed * 73 + 19, 10007)) / 10007.0 * TAU
    var pose := Transform3D(Basis(Vector3.UP, yaw), Vector3(local.x, 0.0, local.y))
    return {"canonical": canonical, "transform": pose, "road_distance_m": road_distance,
        "pavement_clearance_m": finished_clearance, "source_type": "industrial_or_warehouse",
        "presentation_inference": true}

static func _cell_key(cell: Vector2i) -> String:
    return "%d:%d" % [cell.x, cell.y]

static func _cell_from_key(key: String) -> Vector2i:
    var pieces := key.split(":")
    if pieces.size() != 2:
        return Vector2i(999999, 999999)
    return Vector2i(int(pieces[0]), int(pieces[1]))

static func asset_contract() -> Dictionary:
    return {
        "file": BARREL_FILE,
        "accepted_building_types": ["industrial", "warehouse"],
        "max_barrels_per_cell": MAX_BARRELS_PER_CELL,
        "visibility_m": VISIBILITY_END_M,
        "collision": false,
        "shadows": false,
        "source_scale_preserved": true,
        "residential_placement": false,
        "commercial_placement": false,
        "asset_absent_fallback": true,
    }
