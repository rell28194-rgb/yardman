extends Node

# Visual-only work-zone cues derived from explicit OSM construction tags.
# This singleton never changes navigation/topology and stays inert when the
# optional private recovered cone is absent.
const References = preload("res://scripts/reference_assets.gd")
const CONE_FILES := ["road_repair_cone.glb", "RoadRepair_Cone.glb"]
const CONE_HEIGHT_M := 0.55
const SPACING_M := 34.0
const MAX_CONES_PER_TILE := 32

var _roads: Node
var _terrain: Node
var _pending: Dictionary = {}
var _cone_mesh: ArrayMesh
var _connected := false

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
    _connected = true
    set_process(false)

func _on_road_tile(tile: Vector2i, tile_root: Node3D, _segments: Array) -> void:
    _pending[tile] = tile_root
    if _terrain != null and _terrain.is_tile_ready(tile):
        _decorate(tile, tile_root)

func _on_terrain_tile(tile: Vector2i) -> void:
    var tile_root = _pending.get(tile)
    if tile_root != null and is_instance_valid(tile_root):
        _decorate(tile, tile_root)

func _on_road_tile_removed(tile: Vector2i) -> void:
    _pending.erase(tile)

static func cone_pose_is_valid(local_x: float, local_z: float, ground_y: float, yaw: float) -> bool:
    return is_finite(local_x) and is_finite(local_z) and is_finite(ground_y) and is_finite(yaw)

func _decorate(tile: Vector2i, tile_root: Node3D) -> void:
    if tile_root == null or not is_instance_valid(tile_root):
        return
    var existing := tile_root.get_node_or_null("RoadworkProxy")
    if existing != null:
        existing.queue_free()
    var records := _load_tile(tile)
    if records.is_empty():
        _pending.erase(tile)
        return
    var mesh := _get_cone_mesh()
    if mesh == null:
        # Public CI/builds intentionally remain valid without private bytes.
        _pending.erase(tile)
        return
    var plan := placement_plan(records, tile, float(_roads.tile_size))
    if plan.is_empty():
        _pending.erase(tile)
        return
    # Terrain height intentionally returns NAN for water/non-land or unavailable
    # height samples. Compact only terrain-supported cone poses before creating
    # the MultiMesh so invalid roadside candidates can never reach RenderingServer.
    var transforms: Array[Transform3D] = []
    for item: Dictionary in plan:
        var world_x := float(item.world_x)
        var world_z := float(item.world_z)
        var ground_y := float(_terrain.height_at(world_x, world_z))
        var yaw := float(item.yaw)
        var local_x := float(item.local_x)
        var local_z := float(item.local_z)
        if not cone_pose_is_valid(local_x, local_z, ground_y, yaw):
            continue
        transforms.append(Transform3D(Basis(Vector3.UP, yaw), Vector3(local_x, ground_y + 0.02, local_z)))
    if transforms.is_empty():
        _pending.erase(tile)
        return
    var multi := MultiMesh.new()
    multi.transform_format = MultiMesh.TRANSFORM_3D
    multi.mesh = mesh
    multi.instance_count = transforms.size()
    for index in range(transforms.size()):
        multi.set_instance_transform(index, transforms[index])
    var instance := MultiMeshInstance3D.new()
    instance.name = "RoadworkProxy"
    instance.multimesh = multi
    instance.visibility_range_end = 650.0
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    instance.set_meta("roadwork_cones", transforms.size())
    instance.set_meta("placement_source", "OSM construction-tagged ways; cone positions inferred along tagged geometry")
    tile_root.add_child(instance)
    _pending.erase(tile)

func _load_tile(tile: Vector2i) -> Array:
    var path := "res://data/roads/roadworks/tile_%d_%d.json" % [tile.x, tile.y]
    if not FileAccess.file_exists(path):
        return []
    var payload = JSON.parse_string(FileAccess.get_file_as_string(path))
    if not payload is Dictionary or not payload.get("roadworks", null) is Array:
        push_warning("Invalid Yardman roadwork tile: " + path)
        return []
    return payload.roadworks

func placement_plan(records: Array, tile: Vector2i, tile_size: float) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    if tile_size <= 0.0 or not is_finite(tile_size):
        return result
    var origin := Vector2(float(tile.x) * tile_size, float(tile.y) * tile_size)
    for record in records:
        if result.size() >= MAX_CONES_PER_TILE:
            break
        if not record is Dictionary:
            continue
        var start_raw = record.get("start", [])
        var end_raw = record.get("end", [])
        if not start_raw is Array or not end_raw is Array or start_raw.size() < 2 or end_raw.size() < 2:
            continue
        var a := Vector2(float(start_raw[0]), float(start_raw[1]))
        var b := Vector2(float(end_raw[0]), float(end_raw[1]))
        if not is_finite(a.x) or not is_finite(a.y) or not is_finite(b.x) or not is_finite(b.y):
            continue
        var delta := b - a
        var length := delta.length()
        if length < 0.5:
            continue
        var tangent := delta / length
        var normal := Vector2(-tangent.y, tangent.x)
        var width := clampf(float(record.get("width_m", 5.8)), 2.0, 24.0)
        var source := str(record.get("source_way", "roadwork"))
        var side := -1.0 if (source.hash() & 1) == 0 else 1.0
        var lateral := width * 0.5 + 0.55
        var count := maxi(1, int(ceil(length / SPACING_M)))
        for step in range(count):
            if result.size() >= MAX_CONES_PER_TILE:
                break
            # Centre samples avoid duplicate cones on split/tile boundaries.
            var fraction := (float(step) + 0.5) / float(count)
            var point := a.lerp(b, fraction) + normal * lateral * side
            result.append({
                "world_x": point.x, "world_z": point.y,
                "local_x": point.x - origin.x, "local_z": point.y - origin.y,
                "yaw": atan2(tangent.x, tangent.y),
                "source_way": source,
            })
    return result

func _get_cone_mesh() -> ArrayMesh:
    if _cone_mesh != null:
        return _cone_mesh
    for filename: String in CONE_FILES:
        var packed := References.scene(filename)
        if packed == null:
            continue
        _cone_mesh = _flatten_scene(packed, CONE_HEIGHT_M)
        if _cone_mesh != null:
            _cone_mesh.set_meta("reference_asset", filename)
            return _cone_mesh
    return null

func _flatten_scene(packed: PackedScene, target_height: float) -> ArrayMesh:
    var source := packed.instantiate()
    if source == null:
        return null
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
    var bounds := combined.get_aabb()
    if bounds.size.y < 0.05:
        return null
    var scale_m := target_height / bounds.size.y
    var center := bounds.position + bounds.size * 0.5
    var correction := Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * scale_m),
        Vector3(-center.x, -bounds.position.y, -center.z) * scale_m)
    var baked := ArrayMesh.new()
    for surface_index in range(combined.get_surface_count()):
        var surface := SurfaceTool.new()
        surface.begin(Mesh.PRIMITIVE_TRIANGLES)
        surface.append_from(combined, surface_index, correction)
        surface.index()
        surface.commit(baked)
        baked.surface_set_material(surface_index, combined.surface_get_material(surface_index))
    return baked

func _collect_surfaces(node: Node, parent_pose: Transform3D, groups: Dictionary) -> void:
    var pose := parent_pose
    if node is Node3D:
        pose = parent_pose * (node as Node3D).transform
    if node is MeshInstance3D:
        var instance := node as MeshInstance3D
        if instance.mesh != null:
            for surface_index in range(instance.mesh.get_surface_count()):
                var material: Material = instance.get_active_material(surface_index)
                var key := material.get_instance_id() if material != null else 0
                if not groups.has(key):
                    var surface := SurfaceTool.new()
                    surface.begin(Mesh.PRIMITIVE_TRIANGLES)
                    groups[key] = {"surface": surface, "material": material}
                var surface: SurfaceTool = groups[key].surface
                surface.append_from(instance.mesh, surface_index, pose)
    for child in node.get_children():
        _collect_surfaces(child, pose, groups)
