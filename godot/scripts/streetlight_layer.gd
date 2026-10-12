extends Node

# Geographic authority is only the compiled Jamaica OSM highway=street_lamp
# dataset. Source-game transforms and inferred national spacing are forbidden.
# Until a source node carries mount/support metadata, runtime uses an original
# orientation-neutral post-top fallback rather than claiming a specific pole type.
const MAX_INSTANCES_PER_TILE := 128
const POLE_HEIGHT_M := 8.2
const FIXTURE_HEIGHT_M := 0.28
const VISIBILITY_RANGE_M := 850.0

var _terrain: Node
var _connected := false
var _fallback_mesh: ArrayMesh

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
    var existing := tile_root.get_node_or_null("StreetLightProxy")
    if existing != null:
        existing.queue_free()
    var records := _load_tile(tile)
    if records.is_empty():
        return
    var plan := placement_plan(records, tile, float(_terrain.tile_size))
    if plan.is_empty():
        return
    var mesh := _get_fallback_mesh()
    if mesh == null:
        return
    var transforms: Array[Transform3D] = []
    for item: Dictionary in plan:
        var world_x := float(item.world_x)
        var world_z := float(item.world_z)
        var ground := float(_terrain.height_at(world_x, world_z))
        if not is_finite(ground):
            continue
        transforms.append(Transform3D(Basis.IDENTITY, Vector3(float(item.local_x), ground + 0.02, float(item.local_z))))
    if transforms.is_empty():
        return
    var multi := MultiMesh.new()
    multi.transform_format = MultiMesh.TRANSFORM_3D
    multi.mesh = mesh
    multi.instance_count = transforms.size()
    for index in range(transforms.size()):
        multi.set_instance_transform(index, transforms[index])
    var instance := MultiMeshInstance3D.new()
    instance.name = "StreetLightFallback"
    instance.multimesh = multi
    instance.visibility_range_end = VISIBILITY_RANGE_M
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    var proxy := Node3D.new()
    proxy.name = "StreetLightProxy"
    proxy.set_meta("placement_source", "explicit Jamaica OSM highway=street_lamp nodes only")
    proxy.set_meta("visual_style", "original orientation-neutral post-top fallback; OSM mount/support unspecified")
    proxy.set_meta("streetlight_instances", transforms.size())
    proxy.add_child(instance)
    tile_root.add_child(proxy)

func _load_tile(tile: Vector2i) -> Array:
    var path := "res://data/roads/streetlights/tile_%d_%d.json" % [tile.x, tile.y]
    if not FileAccess.file_exists(path):
        return []
    var payload = JSON.parse_string(FileAccess.get_file_as_string(path))
    if not payload is Dictionary or not payload.get("street_lights", null) is Array:
        push_warning("Invalid Yardman street-light tile: " + path)
        return []
    return payload.street_lights

func placement_plan(records: Array, tile: Vector2i, tile_size: float) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    if tile_size <= 0.0 or not is_finite(tile_size):
        return result
    var origin := Vector2(float(tile.x) * tile_size, float(tile.y) * tile_size)
    var seen: Dictionary = {}
    for record in records:
        if result.size() >= MAX_INSTANCES_PER_TILE:
            break
        if not record is Dictionary or str(record.get("highway", "")) != "street_lamp":
            continue
        var source_node := str(record.get("source_node", ""))
        var position = record.get("position", [])
        if source_node.is_empty() or seen.has(source_node) or not position is Array or position.size() < 2:
            continue
        var world_x := float(position[0])
        var world_z := float(position[1])
        if not is_finite(world_x) or not is_finite(world_z):
            continue
        # Fail closed if a malformed record was placed in the wrong tile.
        if int(floor(world_x / tile_size)) != tile.x or int(floor(world_z / tile_size)) != tile.y:
            continue
        seen[source_node] = true
        result.append({
            "source_node": source_node,
            "world_x": world_x,
            "world_z": world_z,
            "local_x": world_x - origin.x,
            "local_z": world_z - origin.y,
            "lamp_mount": str(record.get("lamp_mount", "unspecified")),
            "support": str(record.get("support", "unspecified")),
        })
    return result

func _get_fallback_mesh() -> ArrayMesh:
    if _fallback_mesh != null:
        return _fallback_mesh
    var material := StandardMaterial3D.new()
    material.albedo_color = Color(0.50, 0.53, 0.55, 1.0)
    material.metallic = 0.58
    material.roughness = 0.44
    var surface := SurfaceTool.new()
    surface.begin(Mesh.PRIMITIVE_TRIANGLES)

    var pole := CylinderMesh.new()
    pole.height = POLE_HEIGHT_M
    pole.top_radius = 0.075
    pole.bottom_radius = 0.115
    pole.radial_segments = 10
    pole.rings = 2
    surface.append_from(pole, 0, Transform3D(Basis.IDENTITY, Vector3(0.0, POLE_HEIGHT_M * 0.5, 0.0)))

    # Orientation-neutral post-top head. This avoids inventing road-facing yaw
    # when source OSM nodes do not state direction or mount type.
    var head := CylinderMesh.new()
    head.height = FIXTURE_HEIGHT_M
    head.top_radius = 0.24
    head.bottom_radius = 0.34
    head.radial_segments = 12
    head.rings = 1
    surface.append_from(head, 0, Transform3D(Basis.IDENTITY, Vector3(0.0, POLE_HEIGHT_M + FIXTURE_HEIGHT_M * 0.5, 0.0)))

    var cap := SphereMesh.new()
    cap.radius = 0.21
    cap.height = 0.24
    cap.radial_segments = 12
    cap.rings = 4
    surface.append_from(cap, 0, Transform3D(Basis.IDENTITY, Vector3(0.0, POLE_HEIGHT_M + FIXTURE_HEIGHT_M + 0.05, 0.0)))

    surface.index()
    _fallback_mesh = surface.commit()
    if _fallback_mesh != null and _fallback_mesh.get_surface_count() > 0:
        _fallback_mesh.surface_set_material(0, material)
    return _fallback_mesh
