extends Node
class_name YardmanRoadStructureCollision

# Ordinary roads deliberately use the registered terrain collider. Bridges are
# different: their deck must remain independent of the terrain underneath it.
# This listener builds collision only for OSM bridge ribbons after a streamed
# road tile has finished assembling. The StaticBody lives under the tile root,
# so unloading/rebasing the tile also unloads/rebases its bridge collision.

const BRIDGE_FLAG := 2
const DECK_COLLISION_BIAS := 0.12
var roads: Node
var bridge_tiles_built := 0
var bridge_triangles_built := 0

func _ready() -> void:
    call_deferred("_bind_streamer")

func _bind_streamer() -> void:
    roads = get_parent().get_node_or_null("JamaicaRoadStreamer")
    if roads == null:
        # Parent creates the runtime streamers in _ready(). A deferred retry is
        # deterministic and avoids coupling this helper to main.gd construction.
        await get_tree().process_frame
        roads = get_parent().get_node_or_null("JamaicaRoadStreamer")
    if roads == null:
        push_error("Bridge collision helper could not find JamaicaRoadStreamer")
        return
    if not roads.tile_content_ready.is_connected(_on_tile_content_ready):
        roads.tile_content_ready.connect(_on_tile_content_ready)

func _on_tile_content_ready(tile: Vector2i, tile_root: Node3D, segments: Array) -> void:
    var faces := PackedVector3Array()
    var origin_x := float(tile.x) * float(roads.tile_size)
    var origin_z := float(tile.y) * float(roads.tile_size)
    for segment in segments:
        if not segment is Array or segment.size() < 12:
            continue
        if (int(segment[6]) & BRIDGE_FLAG) == 0:
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
            # Backface collision is enabled below; preserve the same fan
            # topology as the visible bridge ribbon to avoid hidden gaps.
            faces.append(local[0])
            faces.append(local[index + 1])
            faces.append(local[index])
    if faces.is_empty():
        return
    var shape := ConcavePolygonShape3D.new()
    shape.backface_collision = true
    shape.set_faces(faces)
    var collider := CollisionShape3D.new()
    collider.name = "BridgeDeckCollisionShape"
    collider.shape = shape
    var body := StaticBody3D.new()
    body.name = "BridgeDeckCollision"
    body.collision_layer = 1
    body.collision_mask = 0
    body.add_child(collider)
    tile_root.add_child(body)
    bridge_tiles_built += 1
    bridge_triangles_built += faces.size() / 3
