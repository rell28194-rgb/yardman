extends Node
class_name YardmanBridgeGeometry

# Source bridge geometry uses the compiled road profile for deck position, width,
# endpoints and stationing. Piers are deterministic inferred presentation only;
# they require finite registered terrain and never mutate terrain/hydrology data.

const BRIDGE_FLAG := 2
const DECK_THICKNESS_M := 0.55
const DECK_OVERHANG_M := 0.35
const RAIL_HEIGHT_M := 1.05
const RAIL_THICKNESS_M := 0.14
const RAIL_OUTSET_M := 0.10
const ABUTMENT_HEIGHT_M := 2.2
const ABUTMENT_DEPTH_M := 1.2
const ABUTMENT_OVERHANG_M := 0.75
const PIER_SPACING_M := 24.0
const PIER_MIN_CLEARANCE_M := 2.5
const PIER_MAX_CLEARANCE_M := 60.0
const PIER_COLUMN_M := 0.72
const PIER_DEPTH_M := 1.0
const PIER_EDGE_MARGIN_M := 10.0

var roads: Node
var terrain: Node
var bridge_tiles_built := 0
var deck_spans_built := 0
var rails_built := 0
var abutments_built := 0
var pier_stations_built := 0
var pier_columns_built := 0
var _segments_by_tile: Dictionary = {}
var _concrete: StandardMaterial3D
var _rail: StandardMaterial3D

func _ready() -> void:
    call_deferred("_bind_streamers")

func _bind_streamers() -> void:
    roads = get_parent().get_node_or_null("JamaicaRoadStreamer")
    terrain = get_parent().get_node_or_null("JamaicaTerrainStreamer")
    if roads == null or terrain == null:
        await get_tree().process_frame
        roads = get_parent().get_node_or_null("JamaicaRoadStreamer")
        terrain = get_parent().get_node_or_null("JamaicaTerrainStreamer")
    if roads == null or terrain == null:
        push_error("Bridge geometry helper could not find road/terrain streamers")
        return
    if not roads.tile_content_ready.is_connected(_on_road_tile_ready):
        roads.tile_content_ready.connect(_on_road_tile_ready)
    if not roads.tile_removed.is_connected(_on_road_tile_removed):
        roads.tile_removed.connect(_on_road_tile_removed)
    if not terrain.tile_ready.is_connected(_on_terrain_tile_ready):
        terrain.tile_ready.connect(_on_terrain_tile_ready)

func _on_road_tile_ready(tile: Vector2i, tile_root: Node3D, segments: Array) -> void:
    var key := _tile_key(tile)
    _segments_by_tile[key] = segments.duplicate(true)
    _build_tile(tile, tile_root, segments)

func _on_road_tile_removed(tile: Vector2i) -> void:
    _segments_by_tile.erase(_tile_key(tile))

func _on_terrain_tile_ready(tile: Vector2i) -> void:
    if roads == null:
        return
    var key := _tile_key(tile)
    if not _segments_by_tile.has(key):
        return
    var tile_root = roads._loaded.get(key)
    if tile_root is Node3D:
        _build_tile(tile, tile_root, _segments_by_tile[key])

func _tile_key(tile: Vector2i) -> String:
    return "%d:%d" % [tile.x, tile.y]

func _concrete_material() -> StandardMaterial3D:
    if _concrete == null:
        _concrete = StandardMaterial3D.new()
        _concrete.albedo_color = Color(0.48, 0.49, 0.47)
        _concrete.roughness = 0.94
    return _concrete

func _rail_material() -> StandardMaterial3D:
    if _rail == null:
        _rail = StandardMaterial3D.new()
        _rail.albedo_color = Color(0.20, 0.21, 0.20)
        _rail.roughness = 0.72
        _rail.metallic = 0.25
    return _rail

func _basis_for(a: Vector3, b: Vector3) -> Basis:
    var forward := b - a
    if forward.length_squared() < 0.000001:
        return Basis.IDENTITY
    forward = forward.normalized()
    var right := Vector3.UP.cross(forward)
    right = Vector3.RIGHT if right.length_squared() < 0.000001 else right.normalized()
    var up := forward.cross(right)
    up = Vector3.UP if up.length_squared() < 0.000001 else up.normalized()
    if up.y < 0.0:
        right = -right
        up = -up
    return Basis(right, up, forward)

func _add_box(parent: Node3D, collision_body: StaticBody3D, name: String,
        size: Vector3, transform: Transform3D, material: Material, collision: bool) -> void:
    if size.x <= 0.0 or size.y <= 0.0 or size.z <= 0.0:
        return
    var mesh := BoxMesh.new()
    mesh.size = size
    var instance := MeshInstance3D.new()
    instance.name = name
    instance.mesh = mesh
    instance.material_override = material
    instance.transform = transform
    parent.add_child(instance)
    if collision and collision_body != null:
        var shape := BoxShape3D.new()
        shape.size = size
        var collider := CollisionShape3D.new()
        collider.name = name + "Collision"
        collider.shape = shape
        collider.transform = transform
        collision_body.add_child(collider)

func _bridge_segment_points(segment: Array, tile: Vector2i) -> PackedVector3Array:
    if segment.size() < 18:
        return PackedVector3Array()
    var origin_x := float(tile.x) * float(roads.tile_size)
    var origin_z := float(tile.y) * float(roads.tile_size)
    return PackedVector3Array([
        Vector3(float(segment[0]) - origin_x, float(segment[9]), float(segment[1]) - origin_z),
        Vector3(float(segment[2]) - origin_x, float(segment[10]), float(segment[3]) - origin_z),
    ])

func _edge_length(edge: Dictionary) -> float:
    var value := float(edge.get("length_m", 0.0))
    if is_finite(value) and value > 0.0:
        return value
    var path: Array = edge.get("path", [])
    var total := 0.0
    for index in range(path.size() - 1):
        var a: Array = path[index]
        var b: Array = path[index + 1]
        if a.size() >= 3 and b.size() >= 3:
            total += Vector2(float(a[0]), float(a[2])).distance_to(Vector2(float(b[0]), float(b[2])))
    return total

func _build_tile(tile: Vector2i, tile_root: Node3D, segments: Array) -> void:
    var old := tile_root.get_node_or_null("BridgeGeometry")
    if old != null:
        tile_root.remove_child(old)
        old.queue_free()
    var bridge_root := Node3D.new()
    bridge_root.name = "BridgeGeometry"
    var collision_body := StaticBody3D.new()
    collision_body.name = "BridgeStructureCollision"
    collision_body.collision_layer = 1
    collision_body.collision_mask = 0
    bridge_root.add_child(collision_body)
    var built := 0
    for segment in segments:
        if segment is Array and segment.size() >= 18 and (int(segment[6]) & BRIDGE_FLAG) != 0:
            if _build_segment(tile, bridge_root, collision_body, segment):
                built += 1
    if built <= 0:
        bridge_root.queue_free()
        return
    tile_root.add_child(bridge_root)
    bridge_tiles_built += 1

func _build_segment(tile: Vector2i, bridge_root: Node3D, collision_body: StaticBody3D, segment: Array) -> bool:
    var points := _bridge_segment_points(segment, tile)
    if points.size() != 2:
        return false
    var a := points[0]
    var b := points[1]
    var span_length := a.distance_to(b)
    if not is_finite(span_length) or span_length < 0.25:
        return false
    var width := clampf(float(segment[4]), 2.5, 32.0)
    var basis := _basis_for(a, b)
    var right := basis.x
    var up := basis.y
    var forward := basis.z
    var center := (a + b) * 0.5
    _add_box(bridge_root, collision_body, "BridgeDeckUnderside",
        Vector3(width + DECK_OVERHANG_M * 2.0, DECK_THICKNESS_M, span_length + 0.08),
        Transform3D(basis, center - up * DECK_THICKNESS_M * 0.5), _concrete_material(), false)
    deck_spans_built += 1
    var rail_offset := width * 0.5 + RAIL_OUTSET_M
    for side in [-1.0, 1.0]:
        _add_box(bridge_root, collision_body, "BridgeRail",
            Vector3(RAIL_THICKNESS_M, RAIL_HEIGHT_M, span_length + 0.10),
            Transform3D(basis, center + right * rail_offset * side + up * (RAIL_HEIGHT_M * 0.5 + 0.08)),
            _rail_material(), true)
        rails_built += 1
    var edge_id := str(segment[7])
    var edge: Dictionary = roads.graph.get_edge(edge_id) if roads != null and roads.graph != null else {}
    var start_station := float(segment[16])
    var end_station := float(segment[17])
    var total_length := _edge_length(edge)
    if start_station <= 0.05:
        _add_abutment(bridge_root, collision_body, a, -forward, basis, width)
    if total_length > 0.0 and absf(end_station - total_length) <= 0.25:
        _add_abutment(bridge_root, collision_body, b, forward, basis, width)
    if total_length > 0.0 and terrain != null:
        _add_piers(tile, bridge_root, collision_body, a, b, basis, width, start_station, end_station, total_length)
    return true

func _add_abutment(parent: Node3D, body: StaticBody3D, endpoint: Vector3,
        outward: Vector3, basis: Basis, width: float) -> void:
    var center := endpoint + outward * (ABUTMENT_DEPTH_M * 0.5) - basis.y * (ABUTMENT_HEIGHT_M * 0.5)
    _add_box(parent, body, "BridgeAbutment",
        Vector3(width + ABUTMENT_OVERHANG_M * 2.0, ABUTMENT_HEIGHT_M, ABUTMENT_DEPTH_M),
        Transform3D(basis, center), _concrete_material(), true)
    abutments_built += 1

func _add_piers(tile: Vector2i, parent: Node3D, body: StaticBody3D, a: Vector3, b: Vector3,
        basis: Basis, width: float, start_station: float, end_station: float, total_length: float) -> void:
    if end_station <= start_station + 0.001 or total_length <= PIER_SPACING_M + PIER_EDGE_MARGIN_M * 2.0:
        return
    var first := int(ceil(maxf(start_station, PIER_EDGE_MARGIN_M) / PIER_SPACING_M))
    var last := int(floor(minf(end_station, total_length - PIER_EDGE_MARGIN_M) / PIER_SPACING_M))
    if last < first:
        return
    var origin_x := float(tile.x) * float(roads.tile_size)
    var origin_z := float(tile.y) * float(roads.tile_size)
    var right := basis.x
    var horizontal_forward := Vector3(basis.z.x, 0.0, basis.z.z)
    horizontal_forward = Vector3.FORWARD if horizontal_forward.length_squared() < 0.000001 else horizontal_forward.normalized()
    var pier_basis := Basis(right, Vector3.UP, horizontal_forward)
    for station_index in range(first, last + 1):
        var station := float(station_index) * PIER_SPACING_M
        if station <= start_station + 0.05 or station >= end_station - 0.05:
            continue
        var t := clampf((station - start_station) / (end_station - start_station), 0.0, 1.0)
        var deck_point := a.lerp(b, t)
        var ground_y := float(terrain.height_at(origin_x + deck_point.x, origin_z + deck_point.z))
        if not is_finite(ground_y):
            continue
        var clearance := deck_point.y - DECK_THICKNESS_M - ground_y
        if clearance < PIER_MIN_CLEARANCE_M or clearance > PIER_MAX_CLEARANCE_M:
            continue
        var offsets: Array[float] = [0.0]
        if width >= 7.0:
            var offset := minf(width * 0.24, 2.6)
            offsets = [-offset, offset]
        for offset in offsets:
            var center := deck_point + right * offset
            center.y = ground_y + clearance * 0.5
            _add_box(parent, body, "BridgePier", Vector3(PIER_COLUMN_M, clearance, PIER_DEPTH_M),
                Transform3D(pier_basis, center), _concrete_material(), true)
            pier_columns_built += 1
        pier_stations_built += 1
