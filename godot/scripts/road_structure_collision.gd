extends Node
class_name YardmanRoadStructureCollision

# Ordinary roads use the registered terrain collider. Bridges and profiled
# negative-layer tunnels cannot: their driving surface is structurally separate
# from terrain below/above it. This listener builds collision from the exact
# streamed road ribbons. The body lives under the road tile root, so normal
# streaming/rebasing removes and moves it automatically.

const BRIDGE_FLAG := 2
const TUNNEL_FLAG := 4
const STRUCTURE_FLAGS := BRIDGE_FLAG | TUNNEL_FLAG
const DECK_COLLISION_BIAS := 0.12
var roads: Node
var bridge_tiles_built := 0
var bridge_triangles_built := 0
var tunnel_tiles_built := 0
var tunnel_triangles_built := 0

func _ready() -> void:
    call_deferred("_bind_streamer")

func _bind_streamer() -> void:
    roads = get_parent().get_node_or_null("JamaicaRoadStreamer")
    if roads == null:
        await get_tree().process_frame
        roads = get_parent().get_node_or_null("JamaicaRoadStreamer")
    if roads == null:
        push_error("Road structure collision helper could not find JamaicaRoadStreamer")
        return
    if not roads.tile_content_ready.is_connected(_on_tile_content_ready):
        roads.tile_content_ready.connect(_on_tile_content_ready)

func _on_tile_content_ready(tile: Vector2i, tile_root: Node3D, segments: Array) -> void:
    var faces := PackedVector3Array()
    var bridge_faces := 0
    var tunnel_faces := 0
    var origin_x := float(tile.x) * float(roads.tile_size)
    var origin_z := float(tile.y) * float(roads.tile_size)
    for segment in segments:
        if not segment is Array or segment.size() < 12:
            continue
        var flags := int(segment[6])
        if (flags & STRUCTURE_FLAGS) == 0:
            continue
        var polygon: Array = segment[11]
        if polygon.size() < 3:
            continue
        var local := PackedVector3Array()
        for point in polygon:
            if not point is Array or point.size() < 3:
                local.clear()
                break
            local.append(Vector3(float(point[0]) - origin_x,
                float(point[1]) + DECK_COLLISION_BIAS,
                float(point[2]) - origin_z))
        if local.size() < 3:
            continue
        for index in range(1, local.size() - 1):
            faces.append(local[0])
            faces.append(local[index + 1])
            faces.append(local[index])
            if (flags & TUNNEL_FLAG) != 0:
                tunnel_faces += 1
            else:
                bridge_faces += 1
    if faces.is_empty():
        return
    var shape := ConcavePolygonShape3D.new()
    shape.backface_collision = true
    shape.set_faces(faces)
    var collider := CollisionShape3D.new()
    collider.name = "RoadStructureDeckCollisionShape"
    collider.shape = shape
    var body := StaticBody3D.new()
    body.name = "RoadStructureDeckCollision"
    body.collision_layer = 1
    body.collision_mask = 0
    body.add_child(collider)
    tile_root.add_child(body)
    if bridge_faces > 0:
        bridge_tiles_built += 1
        bridge_triangles_built += bridge_faces
    if tunnel_faces > 0:
        tunnel_tiles_built += 1
        tunnel_triangles_built += tunnel_faces
