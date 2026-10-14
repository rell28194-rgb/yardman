extends Node

# Geographic authority is only the compiled Jamaica OSM bus-stop point dataset.
# The base marker is orientation-independent. Explicit shelter=yes and bench=yes
# tags may add original rotationally-neutral furniture, so point-only OSM data
# never invents a road-facing yaw; recovered source-game art stays private.
const MAX_INSTANCES_PER_TILE := 96
const POST_HEIGHT_M := 2.75
const POST_RADIUS_M := 0.055
const SIGN_RADIUS_M := 0.22
const SIGN_HEIGHT_M := 0.09
const SHELTER_HEIGHT_M := 2.35
const SHELTER_RADIUS_M := 0.78
const BENCH_HALF_SPAN_M := 0.52
const VISIBILITY_RANGE_M := 650.0

var _terrain: Node
var _connected := false
var _marker_mesh: ArrayMesh
var _shelter_mesh: ArrayMesh
var _bench_mesh: ArrayMesh

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
    var marker_mesh := _get_marker_mesh()
    if marker_mesh == null:
        return

    var marker_transforms: Array[Transform3D] = []
    var shelter_transforms: Array[Transform3D] = []
    var bench_transforms: Array[Transform3D] = []
    for item: Dictionary in plan:
        var world_x := float(item.world_x)
        var world_z := float(item.world_z)
        var ground := float(_terrain.height_at(world_x, world_z))
        if not is_finite(ground):
            continue
        var transform := Transform3D(Basis.IDENTITY, Vector3(float(item.local_x), ground + 0.01, float(item.local_z)))
        marker_transforms.append(transform)
        if bool(item.shelter_explicit):
            shelter_transforms.append(transform)
        if bool(item.bench_explicit):
            bench_transforms.append(transform)
    if marker_transforms.is_empty():
        return

    var proxy := Node3D.new()
    proxy.name = "BusStopProxy"
    proxy.set_meta("placement_source", "explicit Jamaica OSM highway=bus_stop or bus-designated platform nodes only")
    proxy.set_meta("visual_style", "original orientation-neutral stop marker with source-authorized rotationally-neutral shelter/bench furniture")
    proxy.set_meta("bus_stop_instances", marker_transforms.size())
    proxy.set_meta("source_shelter_yes", shelter_transforms.size())
    proxy.set_meta("source_bench_yes", bench_transforms.size())

    var marker_instance := _make_multimesh_instance("BusStopMarkers", marker_mesh, marker_transforms)
    if marker_instance != null:
        proxy.add_child(marker_instance)
    if not shelter_transforms.is_empty():
        var shelter_instance := _make_multimesh_instance("BusStopShelters", _get_shelter_mesh(), shelter_transforms)
        if shelter_instance != null:
            proxy.add_child(shelter_instance)
    if not bench_transforms.is_empty():
        var bench_instance := _make_multimesh_instance("BusStopBenches", _get_bench_mesh(), bench_transforms)
        if bench_instance != null:
            proxy.add_child(bench_instance)
    tile_root.add_child(proxy)

func _make_multimesh_instance(name_value: String, mesh: Mesh, transforms: Array[Transform3D]) -> MultiMeshInstance3D:
    if mesh == null or transforms.is_empty():
        return null
    var multi := MultiMesh.new()
    multi.transform_format = MultiMesh.TRANSFORM_3D
    multi.mesh = mesh
    multi.instance_count = transforms.size()
    for index in range(transforms.size()):
        multi.set_instance_transform(index, transforms[index])
    var instance := MultiMeshInstance3D.new()
    instance.name = name_value
    instance.multimesh = multi
    instance.visibility_range_end = VISIBILITY_RANGE_M
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    return instance

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

func _get_shelter_mesh() -> ArrayMesh:
    if _shelter_mesh != null:
        return _shelter_mesh
    var material := StandardMaterial3D.new()
    material.albedo_color = Color(0.20, 0.23, 0.25, 1.0)
    material.metallic = 0.46
    material.roughness = 0.50
    var surface := SurfaceTool.new()
    surface.begin(Mesh.PRIMITIVE_TRIANGLES)

    # Circular canopy and four symmetric posts remain valid without a road-facing
    # orientation. Their presence is authorized only by explicit shelter tags.
    var canopy := CylinderMesh.new()
    canopy.height = 0.10
    canopy.top_radius = SHELTER_RADIUS_M
    canopy.bottom_radius = SHELTER_RADIUS_M
    canopy.radial_segments = 16
    canopy.rings = 1
    surface.append_from(canopy, 0, Transform3D(Basis.IDENTITY, Vector3(0.0, SHELTER_HEIGHT_M, 0.0)))
    for offset in [Vector2(-0.54, -0.54), Vector2(0.54, -0.54), Vector2(-0.54, 0.54), Vector2(0.54, 0.54)]:
        var support := CylinderMesh.new()
        support.height = SHELTER_HEIGHT_M - 0.08
        support.top_radius = 0.035
        support.bottom_radius = 0.042
        support.radial_segments = 6
        support.rings = 1
        surface.append_from(support, 0, Transform3D(Basis.IDENTITY, Vector3(offset.x, (SHELTER_HEIGHT_M - 0.08) * 0.5, offset.y)))

    surface.index()
    _shelter_mesh = surface.commit()
    if _shelter_mesh != null and _shelter_mesh.get_surface_count() > 0:
        _shelter_mesh.surface_set_material(0, material)
    return _shelter_mesh

func _get_bench_mesh() -> ArrayMesh:
    if _bench_mesh != null:
        return _bench_mesh
    var material := StandardMaterial3D.new()
    material.albedo_color = Color(0.34, 0.29, 0.22, 1.0)
    material.metallic = 0.08
    material.roughness = 0.76
    var surface := SurfaceTool.new()
    surface.begin(Mesh.PRIMITIVE_TRIANGLES)

    # Four equal seat bars form a square ring: usable from any side and therefore
    # safe for point data that has no audited platform/road facing direction.
    for bar in [
        {"size": Vector3(BENCH_HALF_SPAN_M * 2.0, 0.11, 0.18), "pos": Vector3(0.0, 0.46, -BENCH_HALF_SPAN_M)},
        {"size": Vector3(BENCH_HALF_SPAN_M * 2.0, 0.11, 0.18), "pos": Vector3(0.0, 0.46, BENCH_HALF_SPAN_M)},
        {"size": Vector3(0.18, 0.11, BENCH_HALF_SPAN_M * 2.0), "pos": Vector3(-BENCH_HALF_SPAN_M, 0.46, 0.0)},
        {"size": Vector3(0.18, 0.11, BENCH_HALF_SPAN_M * 2.0), "pos": Vector3(BENCH_HALF_SPAN_M, 0.46, 0.0)},
    ]:
        var seat := BoxMesh.new()
        seat.size = bar.size
        surface.append_from(seat, 0, Transform3D(Basis.IDENTITY, bar.pos))
    for offset in [Vector2(-0.42, -0.42), Vector2(0.42, -0.42), Vector2(-0.42, 0.42), Vector2(0.42, 0.42)]:
        var leg := CylinderMesh.new()
        leg.height = 0.42
        leg.top_radius = 0.035
        leg.bottom_radius = 0.045
        leg.radial_segments = 6
        leg.rings = 1
        surface.append_from(leg, 0, Transform3D(Basis.IDENTITY, Vector3(offset.x, 0.21, offset.y)))

    surface.index()
    _bench_mesh = surface.commit()
    if _bench_mesh != null and _bench_mesh.get_surface_count() > 0:
        _bench_mesh.surface_set_material(0, material)
    return _bench_mesh
