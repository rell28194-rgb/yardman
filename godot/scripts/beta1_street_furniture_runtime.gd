extends Node
class_name YardmanBeta1StreetFurnitureRuntime

const References = preload("res://scripts/reference_assets.gd")
const BuiltEnvironment = preload("res://scripts/near_field_built_environment_runtime.gd")

const PROP_FILES := {
    "bin": "settlement_waste_bin.glb",
    "hydrant": "settlement_fire_hydrant.glb",
    "cabinet": "settlement_metal_cabinet.glb",
}
const ACTIVE_RADIUS_M := 190.0
const VISIBILITY_END_M := 105.0
const VISIBILITY_FADE_M := 16.0
const ROAD_SEARCH_M := 30.0
const MAX_PROPS_PER_CELL := 14
const MIN_URBAN_BUILDINGS_FOR_HYDRANT := 8

var _buildings
var _roads
var _terrain
var _meshes: Dictionary = {}
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
    if _buildings != null and is_instance_valid(_buildings) and _buildings.cell_ready.is_connected(_on_cell_ready):
        _buildings.cell_ready.disconnect(_on_cell_ready)
    if _roads != null and is_instance_valid(_roads) and _roads.tile_ready.is_connected(_on_road_tile_ready):
        _roads.tile_ready.disconnect(_on_road_tile_ready)

func _bind_sources() -> void:
    var root: Node = get_parent()
    if root == null:
        return
    _buildings = root.get_node_or_null("JamaicaBuildingStreamer")
    _roads = root.get_node_or_null("JamaicaRoadStreamer")
    _terrain = root.get_node_or_null("JamaicaTerrainStreamer")
    if _buildings == null or _roads == null or _terrain == null:
        return
    if not _buildings.cell_ready.is_connected(_on_cell_ready):
        _buildings.cell_ready.connect(_on_cell_ready)
    if not _roads.tile_ready.is_connected(_on_road_tile_ready):
        _roads.tile_ready.connect(_on_road_tile_ready)
    _load_prop_meshes()
    _last_cell = Vector2i(999999, 999999)
    _refresh_near_cells(true)

func _load_prop_meshes() -> void:
    if not _meshes.is_empty():
        return
    for kind: String in PROP_FILES:
        var mesh := _reference_prop_mesh(str(PROP_FILES[kind]))
        if mesh != null:
            _meshes[kind] = mesh

func _reference_prop_mesh(filename: String) -> ArrayMesh:
    var packed: PackedScene = References.scene(filename)
    if packed == null:
        return null
    var source := packed.instantiate()
    var combined := ArrayMesh.new()
    _collect_surfaces(source, Transform3D.IDENTITY, combined)
    source.free()
    if combined.get_surface_count() == 0:
        return null
    var bounds := combined.get_aabb()
    if not bounds.position.is_finite() or not bounds.size.is_finite() or bounds.size.x < 0.05 or bounds.size.y < 0.10 or bounds.size.z < 0.05 \
            or bounds.size.x > 4.0 or bounds.size.y > 3.0 or bounds.size.z > 4.0:
        return null
    # Preserve recovered metre scale while making the instance origin a stable
    # ground-centred pivot. No source vertex proportions are altered.
    var center := Vector3(bounds.get_center().x, bounds.position.y, bounds.get_center().z)
    var correction := Transform3D(Basis.IDENTITY, -center)
    var baked := ArrayMesh.new()
    for surface_index in range(combined.get_surface_count()):
        var surface := SurfaceTool.new()
        surface.begin(Mesh.PRIMITIVE_TRIANGLES)
        surface.append_from(combined, surface_index, correction)
        surface.index()
        surface.commit(baked)
        baked.surface_set_material(baked.get_surface_count() - 1, combined.surface_get_material(surface_index))
    baked.set_meta("reference_asset", filename)
    baked.set_meta("source_scale_preserved", true)
    return baked

func _collect_surfaces(node: Node, parent_pose: Transform3D, mesh: ArrayMesh) -> void:
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
                surface.commit(mesh)
                mesh.surface_set_material(mesh.get_surface_count() - 1, instance.get_active_material(surface_index))
    for child: Node in node.get_children():
        _collect_surfaces(child, pose, mesh)

func _on_cell_ready(cell: Vector2i, _building_count: int) -> void:
    if _cell_near_active(cell):
        _decorate_cell(cell, true)

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
            var old := cell_root.get_node_or_null("Beta1StreetFurniture")
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

func _decorate_cell(cell: Vector2i, force: bool) -> void:
    var key := "%d:%d" % [cell.x, cell.y]
    if not _buildings._loaded.has(key):
        return
    var entry: Dictionary = _buildings._loaded[key]
    var cell_root := entry.get("root") as Node3D
    if cell_root == null:
        return
    var old := cell_root.get_node_or_null("Beta1StreetFurniture")
    if old != null:
        if not force:
            return
        old.free()
    if _meshes.is_empty():
        return
    var walls := cell_root.get_node_or_null("Walls") as MeshInstance3D
    if walls == null or walls.mesh == null or walls.mesh.get_surface_count() != 1:
        return
    var arrays: Array = walls.mesh.surface_get_arrays(0)
    var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
    var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
    if vertices.size() < 4 or vertices.size() % 4 != 0:
        return
    var cell_origin := Vector2(float(cell.x) * float(_buildings.cell_size), float(cell.y) * float(_buildings.cell_size))
    var building_count := int(entry.get("count", 0))
    var plans: Array[Dictionary] = []
    var occupied: Dictionary = {}
    for offset in range(0, vertices.size(), 4):
        if plans.size() >= MAX_PROPS_PER_CELL:
            break
        var edge := BuiltEnvironment._edge_from_wall(vertices, normals, offset)
        if edge.is_empty():
            continue
        var world_mid := cell_origin + Vector2(edge.mid.x, edge.mid.z)
        var occupancy := Vector2i(floori(world_mid.x / 8.0), floori(world_mid.y / 8.0))
        if occupied.has(occupancy):
            continue
        var candidates: Dictionary = _roads._nearby_surface_segments(world_mid.x, world_mid.y, ROAD_SEARCH_M)
        var road := BuiltEnvironment._nearest_road(world_mid, candidates.values())
        var seed := ("%d:%d:%d" % [cell.x, cell.y, offset]).hash() & 0x7fffffff
        var plan := plan_prop(edge, road, cell_origin, seed, building_count)
        if plan.is_empty() or not _meshes.has(str(plan.get("kind", ""))):
            continue
        if not _ground_plan(plan):
            continue
        occupied[occupancy] = true
        plans.append(plan)
    _attach_plans(cell_root, plans)

func _ground_plan(plan: Dictionary) -> bool:
    var canonical: Vector2 = plan.get("canonical", Vector2(INF, INF))
    if not canonical.is_finite() or _terrain == null or not is_instance_valid(_terrain):
        return false
    var height := float(_terrain.height_at(canonical.x, canonical.y))
    if not is_finite(height) or height < -50.0:
        return false
    var pose: Transform3D = plan.get("transform", Transform3D.IDENTITY)
    pose.origin.y = height + 0.025
    plan["transform"] = pose
    return true

func _attach_plans(cell_root: Node3D, plans: Array[Dictionary]) -> void:
    if plans.is_empty():
        return
    var root := Node3D.new()
    root.name = "Beta1StreetFurniture"
    root.set_meta("presentation_inference", true)
    root.set_meta("source_contract", "registered building frontage + compiled road geometry + recovered neutral Beta1 prop meshes")
    root.set_meta("collision", false)
    root.set_meta("construction_props", false)
    root.set_meta("prop_count", plans.size())
    for kind: String in PROP_FILES:
        if not _meshes.has(kind):
            continue
        var entries: Array[Dictionary] = []
        for plan: Dictionary in plans:
            if str(plan.get("kind", "")) == kind:
                entries.append(plan)
        if entries.is_empty():
            continue
        var multi := MultiMesh.new()
        multi.transform_format = MultiMesh.TRANSFORM_3D
        multi.mesh = _meshes[kind]
        multi.instance_count = entries.size()
        for index in range(entries.size()):
            multi.set_instance_transform(index, entries[index].transform)
        var instance := MultiMeshInstance3D.new()
        instance.name = "Beta1_%s" % kind.capitalize()
        instance.multimesh = multi
        instance.visibility_range_end = VISIBILITY_END_M
        instance.visibility_range_end_margin = VISIBILITY_FADE_M
        instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        instance.set_meta("reference_asset", str(PROP_FILES[kind]))
        root.add_child(instance)
    if root.get_child_count() > 0:
        cell_root.add_child(root)
    else:
        root.free()

static func plan_prop(edge: Dictionary, road: Dictionary, cell_origin: Vector2, seed: int, building_count: int) -> Dictionary:
    if edge.is_empty() or road.is_empty():
        return {}
    var mid: Vector3 = edge.get("mid", Vector3(INF, INF, INF))
    var outward3: Vector3 = edge.get("normal", Vector3.ZERO)
    var world_mid := cell_origin + Vector2(mid.x, mid.z)
    var road_point: Vector2 = road.get("point", Vector2(INF, INF))
    if not world_mid.is_finite() or not road_point.is_finite() or outward3.length_squared() < 0.5:
        return {}
    var to_road := road_point - world_mid
    var distance_m := to_road.length()
    if distance_m < 0.1 or distance_m > ROAD_SEARCH_M:
        return {}
    var outward2 := Vector2(outward3.x, outward3.z).normalized()
    if outward2.dot(to_road / distance_m) < 0.22:
        return {}
    var road_width := maxf(1.0, float(road.get("width_m", road.get("width", 5.5))))
    var clearance := distance_m - road_width * 0.5
    if clearance < 1.0 or clearance > 22.0:
        return {}
    var flags := int(road.get("flags", 0))
    if (flags & 2) != 0 or (flags & 4) != 0:
        return {}
    var tangent3 := Vector3.UP.cross(outward3).normalized()
    if tangent3.length_squared() < 0.5:
        return {}
    var kind := ""
    var canonical := world_mid
    var x_axis := tangent3
    var z_axis := outward3
    if (flags & 8) == 0 and building_count >= MIN_URBAN_BUILDINGS_FOR_HYDRANT and seed % 7 == 0 and clearance >= 3.8:
        kind = "hydrant"
        var toward_facade := (world_mid - road_point).normalized()
        canonical = road_point + toward_facade * (road_width * 0.5 + 1.25)
        x_axis = Vector3.RIGHT
        z_axis = Vector3.FORWARD
    elif seed % 3 == 0 and clearance >= 2.0:
        kind = "bin"
        var lateral := (float(seed % 401) / 400.0 - 0.5) * minf(float(edge.get("length_m", 4.0)) * 0.45, 2.2)
        canonical = world_mid + outward2 * 0.82 + Vector2(tangent3.x, tangent3.z) * lateral
    elif seed % 5 == 0 and clearance >= 1.5:
        kind = "cabinet"
        var side := -1.0 if (seed & 8) == 0 else 1.0
        canonical = world_mid + outward2 * 0.36 + Vector2(tangent3.x, tangent3.z) * minf(float(edge.get("length_m", 4.0)) * 0.30, 1.7) * side
    else:
        return {}
    var local := canonical - cell_origin
    var basis := Basis(x_axis.normalized(), Vector3.UP, z_axis.normalized())
    if basis.determinant() < 0.0:
        basis = Basis(-x_axis.normalized(), Vector3.UP, z_axis.normalized())
    return {"kind": kind, "canonical": canonical, "transform": Transform3D(basis, Vector3(local.x, 0.0, local.y)),
        "presentation_inference": true}

static func asset_contract() -> Dictionary:
    return {
        "files": PROP_FILES.duplicate(),
        "max_props_per_cell": MAX_PROPS_PER_CELL,
        "visibility_m": VISIBILITY_END_M,
        "collision": false,
        "construction_props": false,
        "source_scale_preserved": true,
    }
