extends Node

# Optional private Highway chain-link art may decorate only explicit compatible
# OSM barrier=fence geometry. The OSM fence dataset owns geography; source-game
# transforms never become Jamaica placement authority.
const References = preload("res://scripts/reference_assets.gd")
const FENCE_FILES := [
    {"file": "highway_wired_fence_0.glb", "length": 64.6862640380859},
    {"file": "highway_wired_fence_1.glb", "length": 52.0559234619141},
    {"file": "highway_wired_fence_2.glb", "length": 21.6249980926514},
]
const FENCE_TEXTURE := "highway_wired_fence.png"
const MAX_INSTANCES_PER_TILE := 48
const MAX_SLOPE_DELTA_M := 0.85
const END_TOLERANCE_M := 1.25

var _terrain: Node
var _connected := false
var _mesh_entries: Array[Dictionary] = []
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
    _terrain = scene.get_node_or_null("JamaicaTerrainStreamer")
    if _terrain == null:
        return
    _terrain.tile_ready.connect(_on_terrain_tile)
    _terrain.tile_removed.connect(_on_terrain_tile_removed)
    _connected = true
    set_process(false)

func _on_terrain_tile(tile: Vector2i) -> void:
    var tile_root := _terrain.get_node_or_null("TerrainTile_%d_%d" % [tile.x, tile.y]) as Node3D
    if tile_root != null:
        _decorate(tile, tile_root)

func _on_terrain_tile_removed(_tile: Vector2i) -> void:
    pass

func _decorate(tile: Vector2i, tile_root: Node3D) -> void:
    var existing := tile_root.get_node_or_null("FenceProxy")
    if existing != null:
        existing.queue_free()
    var records := _load_tile(tile)
    if records.is_empty():
        return
    var meshes := _get_mesh_entries()
    if meshes.is_empty():
        return
    var lengths: Array[float] = []
    for entry: Dictionary in meshes:
        lengths.append(float(entry.length))
    var plan := placement_plan(records, tile, float(_terrain.tile_size), lengths)
    if plan.is_empty():
        return
    var proxy := Node3D.new()
    proxy.name = "FenceProxy"
    proxy.set_meta("placement_source", "registered Jamaica OSM barrier=fence; recovered art only on explicit wire-compatible tags")
    var transforms_by_variant: Dictionary = {}
    for item: Dictionary in plan:
        var variant := int(item.variant)
        var length := float(item.length)
        var tangent := Vector2(cos(float(item.yaw)), -sin(float(item.yaw)))
        var centre_x := float(item.world_x)
        var centre_z := float(item.world_z)
        var half := tangent * length * 0.47
        var y0 := float(_terrain.height_at(centre_x - half.x, centre_z - half.y))
        var yc := float(_terrain.height_at(centre_x, centre_z))
        var y1 := float(_terrain.height_at(centre_x + half.x, centre_z + half.y))
        if not is_finite(y0) or not is_finite(yc) or not is_finite(y1):
            continue
        if maxf(absf(y1 - y0), maxf(absf(yc - y0), absf(y1 - yc))) > MAX_SLOPE_DELTA_M:
            continue
        if not transforms_by_variant.has(variant):
            transforms_by_variant[variant] = []
        var local := Vector3(float(item.local_x), yc + 0.015, float(item.local_z))
        transforms_by_variant[variant].append(Transform3D(Basis(Vector3.UP, float(item.yaw)), local))
    for variant in transforms_by_variant.keys():
        var transforms: Array = transforms_by_variant[variant]
        if transforms.is_empty():
            continue
        var multi := MultiMesh.new()
        multi.transform_format = MultiMesh.TRANSFORM_3D
        multi.mesh = meshes[int(variant)].mesh
        multi.instance_count = transforms.size()
        for index in range(transforms.size()):
            multi.set_instance_transform(index, transforms[index])
        var instance := MultiMeshInstance3D.new()
        instance.name = "FenceVariant_%d" % int(variant)
        instance.multimesh = multi
        instance.visibility_range_end = 900.0
        instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        proxy.add_child(instance)
    if proxy.get_child_count() == 0:
        proxy.free()
        return
    proxy.set_meta("fence_instances", plan.size())
    tile_root.add_child(proxy)

func _load_tile(tile: Vector2i) -> Array:
    var path := "res://data/roads/fences/tile_%d_%d.json" % [tile.x, tile.y]
    if not FileAccess.file_exists(path):
        return []
    var payload = JSON.parse_string(FileAccess.get_file_as_string(path))
    if not payload is Dictionary or not payload.get("fences", null) is Array:
        push_warning("Invalid Yardman fence tile: " + path)
        return []
    return payload.fences

func placement_plan(records: Array, tile: Vector2i, tile_size: float, source_lengths: Array[float]) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    if tile_size <= 0.0 or not is_finite(tile_size) or source_lengths.is_empty():
        return result
    var variants: Array[Dictionary] = []
    for index in range(source_lengths.size()):
        var length := float(source_lengths[index])
        if is_finite(length) and length > 1.0:
            variants.append({"variant": index, "length": length})
    variants.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.length) > float(b.length))
    if variants.is_empty():
        return result
    var origin := Vector2(float(tile.x) * tile_size, float(tile.y) * tile_size)
    for record in records:
        if result.size() >= MAX_INSTANCES_PER_TILE:
            break
        if not record is Dictionary or not bool(record.get("wire_compatible", false)):
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
        var segment_length := delta.length()
        if segment_length < float(variants[-1].length) - END_TOLERANCE_M:
            continue
        var tangent := delta / segment_length
        var cursor := 0.0
        while cursor < segment_length and result.size() < MAX_INSTANCES_PER_TILE:
            var remaining := segment_length - cursor
            var chosen: Dictionary = {}
            for candidate: Dictionary in variants:
                if float(candidate.length) <= remaining + END_TOLERANCE_M:
                    chosen = candidate
                    break
            if chosen.is_empty():
                break
            var length := float(chosen.length)
            var centre_distance := minf(cursor + length * 0.5, segment_length - length * 0.5)
            if centre_distance < 0.0:
                break
            var point := a + tangent * centre_distance
            result.append({
                "world_x": point.x,
                "world_z": point.y,
                "local_x": point.x - origin.x,
                "local_z": point.y - origin.y,
                "yaw": atan2(-tangent.y, tangent.x),
                "variant": int(chosen.variant),
                "length": length,
                "source_way": str(record.get("source_way", "fence")),
            })
            cursor += length
    return result

func _get_mesh_entries() -> Array[Dictionary]:
    if not _mesh_entries.is_empty():
        return _mesh_entries
    var texture: Texture2D = References.texture(FENCE_TEXTURE) as Texture2D
    if texture == null:
        return _mesh_entries
    _material = StandardMaterial3D.new()
    _material.albedo_texture = texture
    _material.albedo_color = Color(0.588, 0.588, 0.588, 1.0)
    _material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    _material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
    _material.cull_mode = BaseMaterial3D.CULL_DISABLED
    _material.roughness = 0.82
    _material.metallic = 0.08
    for spec: Dictionary in FENCE_FILES:
        var packed: PackedScene = References.scene(str(spec.file)) as PackedScene
        if packed == null:
            _mesh_entries.clear()
            return _mesh_entries
        var mesh := _flatten_scene(packed)
        if mesh == null:
            _mesh_entries.clear()
            return _mesh_entries
        var bounds := mesh.get_aabb()
        if absf(bounds.size.x - float(spec.length)) > 0.75:
            push_warning("Recovered Highway fence length differs from audited source: " + str(spec.file))
            _mesh_entries.clear()
            return _mesh_entries
        _mesh_entries.append({"mesh": mesh, "length": float(spec.length), "file": str(spec.file)})
    return _mesh_entries

func _flatten_scene(packed: PackedScene) -> ArrayMesh:
    var source := packed.instantiate()
    if source == null:
        return null
    var surface := SurfaceTool.new()
    surface.begin(Mesh.PRIMITIVE_TRIANGLES)
    _append_surfaces(source, Transform3D.IDENTITY, surface)
    surface.index()
    var combined := surface.commit()
    source.free()
    if combined == null or combined.get_surface_count() == 0:
        return null
    var bounds := combined.get_aabb()
    if bounds.size.x < 1.0 or bounds.size.y < 0.2:
        return null
    var correction := Transform3D(Basis.IDENTITY, Vector3(-bounds.get_center().x, -bounds.position.y, -bounds.get_center().z))
    var baked_surface := SurfaceTool.new()
    baked_surface.begin(Mesh.PRIMITIVE_TRIANGLES)
    baked_surface.append_from(combined, 0, correction)
    baked_surface.index()
    var baked := baked_surface.commit()
    baked.surface_set_material(0, _material)
    return baked

func _append_surfaces(node: Node, parent_pose: Transform3D, surface: SurfaceTool) -> void:
    var pose := parent_pose
    if node is Node3D:
        pose = parent_pose * (node as Node3D).transform
    if node is MeshInstance3D:
        var instance := node as MeshInstance3D
        if instance.mesh != null:
            for surface_index in range(instance.mesh.get_surface_count()):
                surface.append_from(instance.mesh, surface_index, pose)
    for child in node.get_children():
        _append_surfaces(child, pose, surface)
