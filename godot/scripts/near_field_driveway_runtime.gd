extends Node3D
class_name YardmanNearFieldDrivewayRuntime

# Presentation-only driveway strips connect a bounded subset of registered,
# road-facing low-rise building edges to the compiled road edge. Building
# footprints, road geometry, terrain height, collision and navigation remain
# authoritative elsewhere.
const References = preload("res://scripts/reference_assets.gd")
const BuiltEnvironment = preload("res://scripts/near_field_built_environment_runtime.gd")

const ACTIVE_RADIUS_M := 205.0
const VISIBILITY_END_M := 135.0
const VISIBILITY_FADE_M := 20.0
const ROAD_SEARCH_M := 30.0
const MIN_CLEARANCE_M := 2.6
const MAX_CLEARANCE_M := 15.0
const MAX_DRIVEWAYS_PER_CELL := 12
const SURFACE_LIFT_M := 0.035

var _buildings
var _roads
var _terrain
var _material: StandardMaterial3D
var _refresh_clock := 0.0
var _last_cell := Vector2i(999999, 999999)

func _ready() -> void:
    call_deferred("_bind_sources")

func _process(delta: float) -> void:
    _refresh_clock += delta
    if _refresh_clock < 0.30:
        return
    _refresh_clock = 0.0
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
    if not _roads.tile_ready.is_connected(_on_road_tile_ready):
        _roads.tile_ready.connect(_on_road_tile_ready)
    _last_cell = Vector2i(999999, 999999)
    _refresh_near_cells(true)

func _on_cell_ready(cell: Vector2i, _building_count: int) -> void:
    if _cell_near_active(cell):
        _decorate_cell(cell, true)

func _on_road_tile_ready(_tile: Vector2i) -> void:
    _refresh_near_cells(true)

func _cell_near_active(cell: Vector2i) -> bool:
    if _buildings == null:
        return false
    var size := float(_buildings.cell_size)
    var center := (Vector2(cell) + Vector2.ONE * 0.5) * size
    return center.distance_to(_buildings._world_position) <= ACTIVE_RADIUS_M + size * 0.72

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
            var old := cell_root.get_node_or_null("NearFieldDriveways")
            if old != null:
                old.free()

func _decorate_cell(cell: Vector2i, force: bool) -> void:
    var key := "%d:%d" % [cell.x, cell.y]
    if not _buildings._loaded.has(key):
        return
    var entry: Dictionary = _buildings._loaded[key]
    var cell_root := entry.get("root") as Node3D
    if cell_root == null:
        return
    var old := cell_root.get_node_or_null("NearFieldDriveways")
    if old != null:
        if not force:
            return
        old.free()
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
    for offset in range(0, vertices.size(), 4):
        if plans.size() >= MAX_DRIVEWAYS_PER_CELL:
            break
        var edge := BuiltEnvironment._edge_from_wall(vertices, normals, offset)
        if edge.is_empty():
            continue
        var world_mid := cell_origin + Vector2(edge.mid.x, edge.mid.z)
        var candidates: Dictionary = _roads._nearby_surface_segments(world_mid.x, world_mid.y, ROAD_SEARCH_M)
        var road := BuiltEnvironment._nearest_road(world_mid, candidates.values())
        var seed := ("driveway:%d:%d:%d" % [cell.x, cell.y, offset]).hash() & 0x7fffffff
        var plan := plan_driveway(edge, road, cell_origin, seed)
        if plan.is_empty():
            continue
        var center: Vector2 = plan.get("center", Vector2(INF, INF))
        var slot := Vector2i(floori(center.x / 10.0), floori(center.y / 10.0))
        if occupied.has(slot):
            continue
        if not _ground_plan(plan):
            continue
        occupied[slot] = true
        plans.append(plan)
    if not plans.is_empty():
        _attach_driveways(cell_root, cell_origin, plans)

func _ground_plan(plan: Dictionary) -> bool:
    var corners: Array = plan.get("corners", [])
    if corners.size() != 4 or _terrain == null or not is_instance_valid(_terrain):
        return false
    var grounded: Array[Vector3] = []
    for raw: Variant in corners:
        if not raw is Vector2:
            return false
        var point := raw as Vector2
        if not point.is_finite():
            return false
        var y := float(_terrain.height_at(point.x, point.y))
        if not is_finite(y) or y < -50.0:
            return false
        grounded.append(Vector3(point.x, y + SURFACE_LIFT_M, point.y))
    plan["grounded"] = grounded
    return true

func _attach_driveways(cell_root: Node3D, cell_origin: Vector2, plans: Array[Dictionary]) -> void:
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var uvs := PackedVector2Array()
    var indices := PackedInt32Array()
    for plan: Dictionary in plans:
        var points: Array = plan.get("grounded", [])
        if points.size() != 4:
            continue
        var offset := vertices.size()
        var local: Array[Vector3] = []
        for raw: Variant in points:
            var point := raw as Vector3
            local.append(Vector3(point.x - cell_origin.x, point.y, point.z - cell_origin.y))
        var face_normal := (local[1] - local[0]).cross(local[3] - local[0]).normalized()
        if not face_normal.is_finite() or face_normal.length_squared() < 0.5:
            continue
        if face_normal.y < 0.0:
            face_normal = -face_normal
        vertices.append_array(PackedVector3Array([local[0], local[1], local[2], local[3]]))
        for _index in range(4):
            normals.append(face_normal)
        var width_m := float(plan.get("width_m", 3.0))
        var length_m := float(plan.get("length_m", 5.0))
        uvs.append_array(PackedVector2Array([
            Vector2(0.0, 0.0), Vector2(width_m / 2.4, 0.0),
            Vector2(width_m / 2.4, length_m / 2.4), Vector2(0.0, length_m / 2.4),
        ]))
        # Clockwise from above in Godot: building-left, building-right,
        # road-right and road-left.
        indices.append_array(PackedInt32Array([offset, offset + 2, offset + 1, offset, offset + 3, offset + 2]))
    if vertices.is_empty():
        return
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = normals
    arrays[Mesh.ARRAY_TEX_UV] = uvs
    arrays[Mesh.ARRAY_INDEX] = indices
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    mesh.surface_set_material(0, _driveway_material())
    var instance := MeshInstance3D.new()
    instance.name = "NearFieldDriveways"
    instance.mesh = mesh
    instance.visibility_range_end = VISIBILITY_END_M
    instance.visibility_range_end_margin = VISIBILITY_FADE_M
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    instance.set_meta("presentation_inference", true)
    instance.set_meta("source_contract", "registered building front + compiled paved road edge + registered terrain")
    instance.set_meta("driveway_count", plans.size())
    instance.set_meta("collision", false)
    instance.set_meta("terrain_mutation", false)
    cell_root.add_child(instance)

func _driveway_material() -> StandardMaterial3D:
    if _material != null:
        return _material
    _material = StandardMaterial3D.new()
    _material.albedo_color = Color(0.20, 0.205, 0.195)
    _material.roughness = 0.93
    _material.metallic = 0.0
    var texture := References.texture("road_asphalt_detail.png")
    if texture != null:
        _material.albedo_texture = texture
        _material.albedo_color = Color(0.68, 0.68, 0.65)
    return _material

static func plan_driveway(edge: Dictionary, road: Dictionary, cell_origin: Vector2, seed: int) -> Dictionary:
    if edge.is_empty() or road.is_empty() or seed % 4 != 0:
        return {}
    var mid: Vector3 = edge.get("mid", Vector3(INF, INF, INF))
    var outward3: Vector3 = edge.get("normal", Vector3.ZERO)
    var length_m := float(edge.get("length_m", 0.0))
    if not mid.is_finite() or outward3.length_squared() < 0.5 or length_m < 5.0:
        return {}
    var flags := int(road.get("flags", 0))
    # Driveways are not inferred across bridges/tunnels and currently stay on
    # paved roads so a gravel lane does not acquire a fake asphalt apron.
    if (flags & 2) != 0 or (flags & 4) != 0 or (flags & 8) != 0:
        return {}
    var world_mid := cell_origin + Vector2(mid.x, mid.z)
    var road_point: Vector2 = road.get("point", Vector2(INF, INF))
    if not world_mid.is_finite() or not road_point.is_finite():
        return {}
    var to_road := road_point - world_mid
    var distance_m := to_road.length()
    if distance_m < 0.1:
        return {}
    var outward := Vector2(outward3.x, outward3.z).normalized()
    if outward.dot(to_road / distance_m) < 0.22:
        return {}
    var road_width := maxf(1.0, float(road.get("width_m", 5.5)))
    var clearance := distance_m - road_width * 0.5
    if clearance < MIN_CLEARANCE_M or clearance > MAX_CLEARANCE_M:
        return {}
    var toward_building := (world_mid - road_point).normalized()
    var building_side := world_mid + outward * 0.42
    var road_side := road_point + toward_building * (road_width * 0.5 + 0.20)
    var driveway_axis := road_side - building_side
    var driveway_length := driveway_axis.length()
    if driveway_length < 1.8 or driveway_length > MAX_CLEARANCE_M + 1.5:
        return {}
    var direction := driveway_axis / driveway_length
    var side := Vector2(-direction.y, direction.x)
    var width_m := clampf(2.65 + float((seed >> 3) % 5) * 0.14, 2.65, minf(3.25, length_m * 0.55))
    if width_m < 2.4:
        return {}
    var half := width_m * 0.5
    var corners: Array[Vector2] = [
        building_side - side * half,
        building_side + side * half,
        road_side + side * half,
        road_side - side * half,
    ]
    return {
        "corners": corners,
        "center": building_side.lerp(road_side, 0.5),
        "width_m": width_m,
        "length_m": driveway_length,
        "presentation_inference": true,
    }

static func _cell_from_key(key: String) -> Vector2i:
    var pieces := key.split(":")
    if pieces.size() != 2:
        return Vector2i(999999, 999999)
    return Vector2i(int(pieces[0]), int(pieces[1]))

static func contract() -> Dictionary:
    return {
        "source_contract": "registered building front + compiled paved road edge + registered terrain",
        "surface_asset": "road_asphalt_detail.png",
        "max_driveways_per_cell": MAX_DRIVEWAYS_PER_CELL,
        "visibility_m": VISIBILITY_END_M,
        "bridge_rejected": true,
        "tunnel_rejected": true,
        "unpaved_rejected": true,
        "collision": false,
        "terrain_mutation": false,
        "navigation": false,
    }
