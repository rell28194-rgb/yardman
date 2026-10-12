extends Node

# Geographic authority is only the compiled Jamaica OSM bus-stop point dataset.
# A neutral post marker is orientation-independent. Even where OSM states
# shelter=yes or bench=yes, directional shelter/bench geometry remains withheld
# until an audited orientation rule exists; recovered Highway art stays private.
const MAX_INSTANCES_PER_TILE := 96
const POST_HEIGHT_M := 2.75
const POST_RADIUS_M := 0.055
const SIGN_RADIUS_M := 0.22
const SIGN_HEIGHT_M := 0.09
const VISIBILITY_RANGE_M := 650.0

var _terrain: Node
var _connected := false
var _marker_mesh: ArrayMesh

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
    var existing := tile_root.get_node_or_null("BusStopProxy")
    if existing != null:
        existing.queue_free()
    var records := _load_tile(tile)
    if records.is_empty():
        return
    var plan := placement_plan(records, tile, float(_terrain.tile_size))
    if plan.is_empty():
        return
    var mesh := _get_marker_mesh()
    if mesh == null:
        return
    var transforms: Array[Transform3D] = []
    var shelter_yes := 0
    var bench_yes := 0
    for item: Dictionary in plan:
        var world_x := float(item.world_x)
        var world_z := float(item.world_z)
        var ground := float(_terrain.height_at(world_x, world_z))
        if not is_finite(ground):
            continue
        transforms.append(Transform3D(Basis.IDENTITY, Vector3(float(item.local_x), ground + 0.01, float(item.local_z))))
        if bool(item.shelter_explicit):
            shelter_yes += 1
        if bool(item.bench_explicit):
            bench_yes += 1
    if transforms.is_empty():
        return
    var multi := MultiMesh.new()
    multi.transform_format = MultiMesh.TRANSFORM_3D
    multi.mesh = mesh
    multi.instance_count = transforms.size()
    for index in range(transforms.size()):
        multi.set_instance_transform(index, transforms[index])
    var instance := MultiMeshInstance3D.new()
    instance.name = "BusStopMarkers"
    instance.multimesh = multi
    instance.visibility_range_end = VISIBILITY_RANGE_M
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    var proxy := Node3D.new()
    proxy.name = "BusStopProxy"
    proxy.set_meta("placement_source", "explicit Jamaica OSM highway=bus_stop or bus-designated platform nodes only")
    proxy.set_meta("visual_style", "original orientation-neutral stop marker; shelter/bench directional art withheld")
    proxy.set_meta("bus_stop_instances", transforms.size())
    proxy.set_meta("source_shelter_yes", shelter_yes)
    proxy.set_meta("source_bench_yes", bench_yes)
    proxy.add_child(instance)
    tile_root.add_child(proxy)

func _load_tile(tile: Vector2i) -> Array:
    var path := "res://data/roads/bus_stops/tile_%d_%d.json" % [tile.x, tile.y]
    if not FileAccess.file_exists(path):
        return []
    var payload = JSON.parse_string(FileAccess.get_file_as_string(path))
    if not payload is Dictionary or not payload.get("bus_stops", null) is Array:
        push_warning("Invalid Yardman bus-stop tile: " + path)
        return []
    return payload.bus_stops

func placement_plan(records: Array, tile: Vector2i, tile_size: float) -> Array[Dictionary]:
    var result: Array[Dictionary] = []
    if tile_size <= 0.0 or not is_finite(tile_size):
        return result
    var origin := Vector2(float(tile.x) * tile_size, float(tile.y) * tile_size)
    var seen: Dictionary = {}
    for record in records:
        if result.size() >= MAX_INSTANCES_PER_TILE:
            break
        if not record is Dictionary:
            continue
        var kind := str(record.get("kind", ""))
        if kind != "highway=bus_stop" and kind != "public_transport=platform+bus":
            continue
        var source_node := str(record.get("source_node", ""))
        var position = record.get("position", [])
        if source_node.is_empty() or seen.has(source_node) or not position is Array or position.size() < 2:
            continue
        var world_x := float(position[0])
        var world_z := float(position[1])
        if not is_finite(world_x) or not is_finite(world_z):
            continue
        if int(floor(world_x / tile_size)) != tile.x or int(floor(world_z / tile_size)) != tile.y:
            continue
        seen[source_node] = true
        var shelter := str(record.get("shelter", "unspecified")).to_lower()
        var bench := str(record.get("bench", "unspecified")).to_lower()
        result.append({
            "source_node": source_node,
            "world_x": world_x,
            "world_z": world_z,
            "local_x": world_x - origin.x,
            "local_z": world_z - origin.y,
            "kind": kind,
            "shelter": shelter,
            "bench": bench,
            "shelter_explicit": shelter in ["yes", "true", "1", "designated"],
            "bench_explicit": bench in ["yes", "true", "1", "designated"],
        })
    return result

func _get_marker_mesh() -> ArrayMesh:
    if _marker_mesh != null:
        return _marker_mesh
    var material := StandardMaterial3D.new()
    material.albedo_color = Color(0.72, 0.74, 0.76, 1.0)
    material.metallic = 0.48
    material.roughness = 0.52
    var surface := SurfaceTool.new()
    surface.begin(Mesh.PRIMITIVE_TRIANGLES)

    var post := CylinderMesh.new()
    post.height = POST_HEIGHT_M
    post.top_radius = POST_RADIUS_M
    post.bottom_radius = POST_RADIUS_M * 1.15
    post.radial_segments = 8
    post.rings = 1
    surface.append_from(post, 0, Transform3D(Basis.IDENTITY, Vector3(0.0, POST_HEIGHT_M * 0.5, 0.0)))

    # Horizontal roundel avoids inventing a road-facing yaw for point-only OSM data.
    var sign := CylinderMesh.new()
    sign.height = SIGN_HEIGHT_M
    sign.top_radius = SIGN_RADIUS_M
    sign.bottom_radius = SIGN_RADIUS_M
    sign.radial_segments = 14
    sign.rings = 1
    surface.append_from(sign, 0, Transform3D(Basis.IDENTITY, Vector3(0.0, POST_HEIGHT_M + SIGN_HEIGHT_M * 0.5, 0.0)))

    surface.index()
    _marker_mesh = surface.commit()
    if _marker_mesh != null and _marker_mesh.get_surface_count() > 0:
        _marker_mesh.surface_set_material(0, material)
    return _marker_mesh
