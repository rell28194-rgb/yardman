extends Node
class_name YardmanWorldDetailRuntime

const References = preload("res://scripts/reference_assets.gd")
const FoliageShader = preload("res://shaders/foliage.gdshader")

const CELL_SIZE_M := 256.0
const BUILD_BUDGET_US := 1400
const REFRESH_INTERVAL := 0.30
const MAX_QUEUED_CELLS := 64

const PROFILES := {
    "Performance": {"radius": 1, "samples": 130, "grass_end": 90.0, "bush_end": 150.0, "tree_near": 130.0, "tree_far": 420.0, "shadows": false},
    "Balanced": {"radius": 2, "samples": 250, "grass_end": 135.0, "bush_end": 220.0, "tree_near": 190.0, "tree_far": 650.0, "shadows": true},
    "Quality": {"radius": 2, "samples": 360, "grass_end": 180.0, "bush_end": 300.0, "tree_near": 240.0, "tree_far": 820.0, "shadows": true},
    "Ultra": {"radius": 3, "samples": 470, "grass_end": 220.0, "bush_end": 360.0, "tree_near": 300.0, "tree_far": 1000.0, "shadows": true},
    "Custom": {"radius": 2, "samples": 300, "grass_end": 160.0, "bush_end": 260.0, "tree_near": 220.0, "tree_far": 760.0, "shadows": true},
}

var _game: Node
var _roads: Variant
var _terrain: Variant
var _refresh_clock: float = 0.0
var _last_center := Vector2i(999999, 999999)
var _last_quality: String = ""
var _cells: Dictionary = {}
var _queue: Array[Vector2i] = []
var _building: Dictionary = {}
var _meshes: Dictionary = {}
var _reference_mesh_cache: Dictionary = {}

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    set_process(true)
    call_deferred("_try_attach")

func _process(delta: float) -> void:
    if _game == null:
        _try_attach()
        return
    _refresh_clock += delta
    if _refresh_clock >= REFRESH_INTERVAL:
        _refresh_clock = 0.0
        _refresh_cells(false)
    _process_build()

func _try_attach() -> void:
    if get_tree() == null:
        return
    var candidate: Node = get_tree().current_scene
    if candidate == null:
        return
    var roads: Variant = candidate.get("roads")
    var terrain: Variant = candidate.get("terrain")
    if roads == null or terrain == null:
        call_deferred("_try_attach")
        return
    _game = candidate
    _roads = roads
    _terrain = terrain
    if _terrain.has_signal("tile_removed"):
        _terrain.tile_removed.connect(_on_terrain_tile_removed)
    if _terrain.has_signal("tile_ready"):
        _terrain.tile_ready.connect(func(_tile: Vector2i) -> void: _refresh_cells(true))
    _refresh_cells(true)

func _quality_name() -> String:
    if _game == null:
        return "Balanced"
    var visuals: Variant = _game.get("visuals")
    if visuals == null:
        return "Balanced"
    var value: String = str(visuals.get("quality"))
    return value if PROFILES.has(value) else "Balanced"

func _profile() -> Dictionary:
    return PROFILES.get(_quality_name(), PROFILES["Balanced"]) as Dictionary

func _active_target() -> Node3D:
    if _game == null:
        return null
    var player: Variant = _game.get("player")
    var car: Variant = _game.get("car")
    if player != null and bool(player.get("in_vehicle")) and car is Node3D:
        return car as Node3D
    if player is Node3D:
        return player as Node3D
    return car as Node3D if car is Node3D else null

func _world_position() -> Vector2:
    var target: Node3D = _active_target()
    if target == null or _roads == null:
        return Vector2.ZERO
    var world: PackedFloat64Array = _roads.local_to_world(target.position)
    return Vector2(float(world[0]), float(world[2]))

func _cell_for_world(point: Vector2) -> Vector2i:
    return Vector2i(floori(point.x / CELL_SIZE_M), floori(point.y / CELL_SIZE_M))

func _cell_key(cell: Vector2i) -> String:
    return "%d:%d" % [cell.x, cell.y]

func _refresh_cells(force: bool) -> void:
    if _roads == null or _terrain == null:
        return
    var center: Vector2i = _cell_for_world(_world_position())
    var quality: String = _quality_name()
    if not force and center == _last_center and quality == _last_quality:
        return
    _last_center = center
    _last_quality = quality
    var profile: Dictionary = _profile()
    var radius: int = clampi(int(profile.get("radius", 2)), 1, 4)
    var wanted: Dictionary = {}
    var candidates: Array[Vector2i] = []
    for dz: int in range(-radius, radius + 1):
        for dx: int in range(-radius, radius + 1):
            var cell := Vector2i(center.x + dx, center.y + dz)
            var key: String = _cell_key(cell)
            wanted[key] = true
            if not _cells.has(key) and not _building_matches(cell):
                candidates.append(cell)
    for raw_key: Variant in _cells.keys():
        var key: String = str(raw_key)
        if wanted.has(key):
            continue
        var node: Node = _cells[key] as Node
        if is_instance_valid(node):
            node.queue_free()
        _cells.erase(key)
    candidates.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
        return a.distance_squared_to(center) < b.distance_squared_to(center))
    _queue.clear()
    for cell: Vector2i in candidates:
        if _queue.size() >= MAX_QUEUED_CELLS:
            break
        _queue.append(cell)

func _building_matches(cell: Vector2i) -> bool:
    return not _building.is_empty() and _building.get("cell", Vector2i(999999, 999999)) == cell

func _process_build() -> void:
    if _building.is_empty():
        _start_next_cell()
    if _building.is_empty():
        return
    var start: int = Time.get_ticks_usec()
    var profile: Dictionary = _profile()
    var sample_count: int = int(profile.get("samples", 250))
    while int(_building.cursor) < sample_count and Time.get_ticks_usec() - start < BUILD_BUDGET_US:
        _sample_candidate(int(_building.cursor))
        _building.cursor = int(_building.cursor) + 1
    if int(_building.cursor) >= sample_count:
        _finish_cell()

func _start_next_cell() -> void:
    while not _queue.is_empty():
        var cell: Vector2i = _queue.pop_front()
        var center_world := Vector2((float(cell.x) + 0.5) * CELL_SIZE_M, (float(cell.y) + 0.5) * CELL_SIZE_M)
        var tile: Vector2i = _roads.coordinates.tile_for(center_world.x, center_world.y)
        if not bool(_terrain.is_tile_ready(tile)):
            continue
        var tile_key: String = str(_roads._tile_key(tile.x, tile.y))
        var tile_root: Variant = _terrain._loaded.get(tile_key)
        if not tile_root is Node3D:
            continue
        _building = {
            "cell": cell,
            "tile": tile,
            "parent": tile_root,
            "cursor": 0,
            "grass": [],
            "bush": [],
            "tree": [],
            "palm": [],
        }
        return

func _sample_candidate(index: int) -> void:
    var cell: Vector2i = _building.cell
    var sx: int = _seed(cell, index, 17)
    var sz: int = _seed(cell, index, 41)
    var selector: int = _seed(cell, index, 83)
    var world_x: float = (float(cell.x) + _unit_float(sx)) * CELL_SIZE_M
    var world_z: float = (float(cell.y) + _unit_float(sz)) * CELL_SIZE_M
    var height: float = float(_terrain.height_at(world_x, world_z))
    if not is_finite(height) or height < 1.2:
        return

    var species: String = "grass"
    var roll: int = selector % 1000
    if roll >= 930:
        species = "palm" if height < 360.0 else "tree"
    elif roll >= 825:
        species = "tree"
    elif roll >= 675:
        species = "bush"

    var road: Dictionary = _roads.road_surface_at(world_x, world_z)
    var road_margin: float = 1.6 if species == "grass" else (3.2 if species == "bush" else 5.5)
    if bool(road.get("found", false)):
        return
    if is_finite(float(road.get("distance_m", INF))) and road.has("width_m"):
        if float(road.distance_m) < float(road.width_m) * 0.5 + road_margin:
            return

    var slope_step: float = 2.5 if species == "grass" else 4.0
    var hx: float = float(_terrain.height_at(world_x + slope_step, world_z))
    var hz: float = float(_terrain.height_at(world_x, world_z + slope_step))
    if not is_finite(hx) or not is_finite(hz):
        return
    var slope: float = Vector2(hx - height, hz - height).length() / slope_step
    var slope_limit: float = 0.85 if species == "grass" else (0.58 if species == "bush" else 0.42)
    if slope > slope_limit:
        return

    var tile: Vector2i = _building.tile
    var local := Vector3(world_x - float(tile.x) * float(_terrain.tile_size), height,
        world_z - float(tile.y) * float(_terrain.tile_size))
    var angle: float = _unit_float(_seed(cell, index, 113)) * TAU
    var scale_noise: float = _unit_float(_seed(cell, index, 151))
    var scale_value: float = 1.0
    match species:
        "grass":
            scale_value = lerpf(0.70, 1.55, scale_noise)
        "bush":
            scale_value = lerpf(0.65, 1.20, scale_noise)
        "palm":
            scale_value = lerpf(0.74, 1.18, scale_noise)
        _:
            scale_value = lerpf(0.72, 1.28, scale_noise)
    var basis := Basis(Vector3.UP, angle).scaled(Vector3.ONE * scale_value)
    var pose := Transform3D(basis, local)
    var dryness: float = _regional_dryness(Vector2(world_x, world_z))
    (_building[species] as Array).append({"transform": pose, "seed": selector, "dryness": dryness})

func _finish_cell() -> void:
    var parent: Node3D = _building.parent as Node3D
    if not is_instance_valid(parent):
        _building.clear()
        return
    var cell: Vector2i = _building.cell
    var root := Node3D.new()
    root.name = "WorldDetail_%d_%d" % [cell.x, cell.y]
    root.set_meta("yardman_detail_cell", cell)
    parent.add_child(root)
    var profile: Dictionary = _profile()
    _append_species(root, "grass", _building.grass, 0.0, float(profile.grass_end), false)
    _append_species(root, "bush", _building.bush, 0.0, float(profile.bush_end), false)
    _append_tree_lod(root, "tree", _building.tree, float(profile.tree_near), float(profile.tree_far), bool(profile.shadows))
    _append_tree_lod(root, "palm", _building.palm, float(profile.tree_near), float(profile.tree_far), bool(profile.shadows))
    _cells[_cell_key(cell)] = root
    _building.clear()

func _append_tree_lod(root: Node3D, species: String, entries: Array, near_end: float, far_end: float, shadows: bool) -> void:
    if entries.is_empty():
        return
    _append_species(root, species, entries, 0.0, near_end, shadows)
    var far_species: String = species + "_far"
    if _mesh_for(far_species) != null:
        _append_species(root, far_species, entries, near_end * 0.82, far_end, false)

func _append_species(root: Node3D, species: String, entries: Array, range_begin: float, range_end: float, shadows: bool) -> void:
    if entries.is_empty():
        return
    var mesh: Mesh = _mesh_for(species)
    if mesh == null:
        return
    var multi := MultiMesh.new()
    multi.transform_format = MultiMesh.TRANSFORM_3D
    multi.use_colors = true
    multi.use_custom_data = true
    multi.mesh = mesh
    multi.instance_count = entries.size()
    for i: int in range(entries.size()):
        var entry: Dictionary = entries[i]
        multi.set_instance_transform(i, entry.transform)
        multi.set_instance_color(i, Color.WHITE)
        var seed_value: int = int(entry.seed)
        multi.set_instance_custom_data(i, Color(float(seed_value % 997) / 997.0,
            float(seed_value % 421) / 421.0, float(entry.dryness), 1.0))
    var instance := MultiMeshInstance3D.new()
    instance.name = species.capitalize()
    instance.multimesh = multi
    instance.visibility_range_begin = maxf(range_begin, 0.0)
    instance.visibility_range_end = maxf(range_end, range_begin + 1.0)
    instance.visibility_range_begin_margin = 12.0
    instance.visibility_range_end_margin = 18.0
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    instance.extra_cull_margin = 3.0
    root.add_child(instance)

func _mesh_for(species: String) -> Mesh:
    if _meshes.has(species):
        return _meshes[species] as Mesh
    var mesh: Mesh = null
    match species:
        "tree":
            mesh = _reference_plant_mesh("road_tree_near.glb", 9.0)
            if mesh == null:
                mesh = _fallback_tree()
        "tree_far":
            mesh = _reference_plant_mesh("road_tree.glb", 9.0)
        "palm":
            mesh = _reference_plant_mesh("road_palm.glb", 12.0)
            if mesh == null:
                mesh = _fallback_palm()
        "palm_far":
            mesh = _reference_plant_mesh("road_palm_lod.glb", 12.0)
        "bush":
            mesh = _reference_plant_mesh("road_bush.glb", 1.8)
            if mesh == null:
                mesh = _fallback_bush()
        "grass":
            mesh = _grass_mesh()
    if mesh != null:
        _meshes[species] = mesh
    return mesh

func _reference_plant_mesh(filename: String, height_m: float) -> ArrayMesh:
    var cache_key: String = "%s:%.3f" % [filename, height_m]
    if _reference_mesh_cache.has(cache_key):
        return _reference_mesh_cache[cache_key] as ArrayMesh
    var packed: PackedScene = References.scene(filename)
    if packed == null:
        return null
    var source: Node = packed.instantiate()
    var groups: Dictionary = {}
    _collect_surfaces(source, Transform3D.IDENTITY, groups)
    var combined := ArrayMesh.new()
    for group: Dictionary in groups.values():
        var surface: SurfaceTool = group.surface
        surface.index()
        surface.commit(combined)
        combined.surface_set_material(combined.get_surface_count() - 1, group.material)
    source.free()
    if combined.get_surface_count() == 0:
        return null
    var bounds: AABB = combined.get_aabb()
    if bounds.size.y < 0.1:
        return null
    var scale_m: float = height_m / bounds.size.y
    var center: Vector3 = bounds.position + bounds.size * 0.5
    var correction := Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * scale_m),
        Vector3(-center.x, -bounds.position.y, -center.z) * scale_m)
    var baked := ArrayMesh.new()
    for surface_index: int in range(combined.get_surface_count()):
        var tool := SurfaceTool.new()
        tool.begin(Mesh.PRIMITIVE_TRIANGLES)
        tool.append_from(combined, surface_index, correction)
        tool.index()
        tool.commit(baked)
        baked.surface_set_material(surface_index, combined.surface_get_material(surface_index))
    baked.set_meta("yardman_reference_asset", filename)
    _reference_mesh_cache[cache_key] = baked
    return baked

func _collect_surfaces(node: Node, parent_pose: Transform3D, groups: Dictionary) -> void:
    var pose: Transform3D = parent_pose
    if node is Node3D:
        pose = parent_pose * (node as Node3D).transform
    if node is MeshInstance3D:
        var instance := node as MeshInstance3D
        if instance.mesh != null:
            for surface_index: int in range(instance.mesh.get_surface_count()):
                var material: Material = instance.get_active_material(surface_index)
                var key: int = int(material.get_instance_id()) if material != null else 0
                if not groups.has(key):
                    var tool := SurfaceTool.new()
                    tool.begin(Mesh.PRIMITIVE_TRIANGLES)
                    groups[key] = {"surface": tool, "material": material}
                var surface: SurfaceTool = groups[key].surface
                surface.append_from(instance.mesh, surface_index, pose)
    for child: Node in node.get_children():
        _collect_surfaces(child, pose, groups)

func _grass_mesh() -> ArrayMesh:
    var tool := SurfaceTool.new()
    tool.begin(Mesh.PRIMITIVE_TRIANGLES)
    var half: float = 0.22
    var height: float = 0.62
    for angle: float in [0.0, PI * 0.5, PI * 0.25]:
        var right := Vector3(cos(angle), 0.0, sin(angle)) * half
        var a: Vector3 = -right
        var b: Vector3 = right
        var c: Vector3 = right + Vector3.UP * height
        var d: Vector3 = -right + Vector3.UP * height
        for pair: Array in [[a, c, b], [a, d, c]]:
            for vertex: Vector3 in pair:
                tool.set_color(Color(0.82, 0.96, 0.72, clampf(vertex.y / height, 0.0, 1.0)))
                tool.add_vertex(vertex)
    tool.generate_normals()
    var mesh: ArrayMesh = tool.commit()
    var material := ShaderMaterial.new()
    material.shader = FoliageShader
    material.set_shader_parameter("tint", Color(0.30, 0.48, 0.13))
    material.set_shader_parameter("wind_strength", 0.08)
    mesh.surface_set_material(0, material)
    return mesh

func _fallback_bush() -> Mesh:
    var mesh := SphereMesh.new()
    mesh.radius = 0.9
    mesh.height = 1.5
    mesh.radial_segments = 8
    mesh.rings = 5
    var material := StandardMaterial3D.new()
    material.albedo_color = Color(0.16, 0.34, 0.09)
    material.roughness = 0.95
    mesh.material = material
    return mesh

func _fallback_tree() -> Mesh:
    var mesh := PrismMesh.new()
    mesh.size = Vector3(4.4, 8.5, 4.4)
    var material := StandardMaterial3D.new()
    material.albedo_color = Color(0.13, 0.31, 0.10)
    material.roughness = 0.92
    mesh.material = material
    return mesh

func _fallback_palm() -> Mesh:
    var mesh := PrismMesh.new()
    mesh.size = Vector3(4.0, 11.5, 4.0)
    var material := StandardMaterial3D.new()
    material.albedo_color = Color(0.18, 0.37, 0.10)
    material.roughness = 0.92
    mesh.material = material
    return mesh

func _regional_dryness(point: Vector2) -> float:
    var south: float = smoothstep(-18000.0, 18000.0, point.y)
    var west: float = 1.0 - smoothstep(-90000.0, 15000.0, point.x)
    return clampf(0.12 + south * 0.30 + west * south * 0.18, 0.1, 0.6)

func _seed(cell: Vector2i, index: int, salt: int) -> int:
    var value: int = int(cell.x) * 73856093
    value = value ^ (int(cell.y) * 19349663)
    value = value ^ (index * 83492791)
    value = value ^ (salt * 2654435761)
    value = value ^ (value >> 13)
    value *= 1274126177
    value = value ^ (value >> 16)
    return value & 0x7fffffff

func _unit_float(value: int) -> float:
    return float(value % 1000003) / 1000003.0

func _on_terrain_tile_removed(tile: Vector2i) -> void:
    for raw_key: Variant in _cells.keys():
        var key: String = str(raw_key)
        var node: Node = _cells[key] as Node
        if not is_instance_valid(node):
            _cells.erase(key)
            continue
        var cell: Vector2i = node.get_meta("yardman_detail_cell", Vector2i(999999, 999999))
        var center_world := Vector2((float(cell.x) + 0.5) * CELL_SIZE_M, (float(cell.y) + 0.5) * CELL_SIZE_M)
        if _roads.coordinates.tile_for(center_world.x, center_world.y) == tile:
            _cells.erase(key)
    if not _building.is_empty() and _building.get("tile", Vector2i(999999, 999999)) == tile:
        _building.clear()
