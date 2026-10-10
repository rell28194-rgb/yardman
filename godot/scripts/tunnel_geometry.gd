extends Node
class_name YardmanTunnelGeometry

# Jamaica's base terrain is a height surface. A real tunnel therefore needs
# three separate pieces: a small opening in that surface at each true portal,
# an independent road deck below the mountain, and an interior shell that hides
# the terrain underside. Road deck collision is handled by
# road_structure_collision.gd; this node owns the portal hole and tunnel shell.

const STRUCTURE_ROOT := "res://data/roads/structures"
const PORTAL_ROOT := "res://data/roads/tunnel_portals"
const MASK_RESOLUTION := 1024
const PORTAL_INSET_M := 24.0
const PORTAL_OUTSET_M := 3.0
const PORTAL_MARGIN_M := 1.4
const COLLISION_DETAIL_M := 4.0
const TUNNEL_CLEARANCE_M := 5.2
const WALL_THICKNESS_M := 0.42
const CEILING_THICKNESS_M := 0.45

var terrain: Node
var portal_tiles_built := 0
var tunnel_segments_built := 0
var collision_triangles_removed := 0
var _tunnel_material: StandardMaterial3D

func _ready() -> void:
    call_deferred("_bind_terrain")

func _bind_terrain() -> void:
    terrain = get_parent().get_node_or_null("JamaicaTerrainStreamer")
    if terrain == null:
        await get_tree().process_frame
        terrain = get_parent().get_node_or_null("JamaicaTerrainStreamer")
    if terrain == null:
        push_error("Tunnel geometry helper could not find JamaicaTerrainStreamer")
        return
    if not terrain.tile_ready.is_connected(_on_terrain_tile_ready):
        terrain.tile_ready.connect(_on_terrain_tile_ready)

func _read_json(path: String) -> Dictionary:
    if not FileAccess.file_exists(path):
        return {}
    var payload = JSON.parse_string(FileAccess.get_file_as_string(path))
    return payload if payload is Dictionary else {}

func _on_terrain_tile_ready(tile: Vector2i) -> void:
    if terrain == null:
        return
    var key: String = terrain._tile_key(tile.x, tile.y)
    var tile_root = terrain._loaded.get(key)
    if not tile_root is Node3D:
        return
    var structure_payload := _read_json("%s/tile_%d_%d.json" % [STRUCTURE_ROOT, tile.x, tile.y])
    var portal_payload := _read_json("%s/tile_%d_%d.json" % [PORTAL_ROOT, tile.x, tile.y])
    var tunnels: Array = structure_payload.get("tunnels", [])
    var portals: Array = portal_payload.get("portals", [])
    if not tunnels.is_empty():
        _build_tunnel_shell(tile, tile_root, tunnels)
    if not portals.is_empty():
        var local_portals := _prepare_portals(tile, portals)
        if not local_portals.is_empty():
            _apply_portal_mask(tile_root, local_portals)
            _carve_portal_collision(tile_root, local_portals)
            portal_tiles_built += 1

func _prepare_portals(tile: Vector2i, portals: Array) -> Array:
    var result: Array = []
    var origin := Vector2(float(tile.x) * float(terrain.tile_size), float(tile.y) * float(terrain.tile_size))
    for raw in portals:
        if not raw is Dictionary:
            continue
        var p: Array = raw.get("position", [])
        var q: Array = raw.get("toward", [])
        if p.size() < 3 or q.size() < 3:
            continue
        var portal := Vector2(float(p[0]) - origin.x, float(p[2]) - origin.y)
        var toward := Vector2(float(q[0]) - origin.x, float(q[2]) - origin.y)
        var direction := toward - portal
        if direction.length_squared() < 0.0001:
            continue
        direction = direction.normalized()
        var right := Vector2(-direction.y, direction.x)
        var half_width := maxf(2.2, float(raw.get("width_m", 6.0)) * 0.5 + PORTAL_MARGIN_M)
        var corners := PackedVector2Array([
            portal - direction * PORTAL_OUTSET_M - right * half_width,
            portal - direction * PORTAL_OUTSET_M + right * half_width,
            portal + direction * PORTAL_INSET_M + right * half_width,
            portal + direction * PORTAL_INSET_M - right * half_width,
        ])
        var minimum := corners[0]
        var maximum := corners[0]
        for corner in corners:
            minimum.x = minf(minimum.x, corner.x)
            minimum.y = minf(minimum.y, corner.y)
            maximum.x = maxf(maximum.x, corner.x)
            maximum.y = maxf(maximum.y, corner.y)
        result.append({
            "origin": portal,
            "direction": direction,
            "right": right,
            "half_width": half_width,
            "bounds": Rect2(minimum, maximum - minimum),
        })
    return result

func _inside_portal(point: Vector2, portal: Dictionary) -> bool:
    var portal_origin: Vector2 = portal["origin"]
    var portal_direction: Vector2 = portal["direction"]
    var portal_right: Vector2 = portal["right"]
    var offset: Vector2 = point - portal_origin
    var along := offset.dot(portal_direction)
    if along < -PORTAL_OUTSET_M or along > PORTAL_INSET_M:
        return false
    return absf(offset.dot(portal_right)) <= float(portal["half_width"])

func _apply_portal_mask(tile_root: Node3D, portals: Array) -> void:
    var land := tile_root.get_node_or_null("RegisteredLand") as MeshInstance3D
    if land == null or land.mesh == null or land.mesh.get_surface_count() == 0:
        return
    var material := land.mesh.surface_get_material(0) as ShaderMaterial
    if material == null:
        return
    var image := Image.create(MASK_RESOLUTION, MASK_RESOLUTION, false, Image.FORMAT_R8)
    image.fill(Color(0, 0, 0, 1))
    var metres_per_pixel := float(terrain.tile_size) / float(MASK_RESOLUTION)
    for portal in portals:
        var bounds: Rect2 = portal["bounds"]
        var x0 := clampi(int(floor(bounds.position.x / metres_per_pixel)), 0, MASK_RESOLUTION - 1)
        var y0 := clampi(int(floor(bounds.position.y / metres_per_pixel)), 0, MASK_RESOLUTION - 1)
        var x1 := clampi(int(ceil(bounds.end.x / metres_per_pixel)), 0, MASK_RESOLUTION - 1)
        var y1 := clampi(int(ceil(bounds.end.y / metres_per_pixel)), 0, MASK_RESOLUTION - 1)
        for py in range(y0, y1 + 1):
            for px in range(x0, x1 + 1):
                var point := Vector2((float(px) + 0.5) * metres_per_pixel,
                    (float(py) + 0.5) * metres_per_pixel)
                if _inside_portal(point, portal):
                    image.set_pixel(px, py, Color(1, 0, 0, 1))
    var texture := ImageTexture.create_from_image(image)
    material.set_shader_parameter("tunnel_portal_mask", texture)
    material.set_shader_parameter("tunnel_portal_mask_enabled", true)
    material.set_shader_parameter("terrain_tile_size", float(terrain.tile_size))

func _terrain_collision(tile_root: Node3D) -> CollisionShape3D:
    var best: CollisionShape3D
    var best_faces := -1
    for child in tile_root.get_children():
        if not child is StaticBody3D:
            continue
        for candidate in child.get_children():
            if not candidate is CollisionShape3D:
                continue
            var collider := candidate as CollisionShape3D
            if not collider.shape is ConcavePolygonShape3D:
                continue
            var count := (collider.shape as ConcavePolygonShape3D).get_faces().size()
            if count > best_faces:
                best_faces = count
                best = collider
    return best

func _triangle_bounds(a: Vector3, b: Vector3, c: Vector3) -> Rect2:
    var minimum := Vector2(minf(a.x, minf(b.x, c.x)), minf(a.z, minf(b.z, c.z)))
    var maximum := Vector2(maxf(a.x, maxf(b.x, c.x)), maxf(a.z, maxf(b.z, c.z)))
    return Rect2(minimum, maximum - minimum)

func _could_touch_portal(a: Vector3, b: Vector3, c: Vector3, portals: Array) -> bool:
    var bounds := _triangle_bounds(a, b, c)
    for portal in portals:
        var portal_bounds: Rect2 = portal["bounds"]
        if bounds.intersects(portal_bounds, true):
            return true
    return false

func _centroid_in_portal(a: Vector3, b: Vector3, c: Vector3, portals: Array) -> bool:
    var center := Vector2((a.x + b.x + c.x) / 3.0, (a.z + b.z + c.z) / 3.0)
    for portal in portals:
        if _inside_portal(center, portal):
            return true
    return false

func _barycentric(a: Vector3, b: Vector3, c: Vector3, u: float, v: float) -> Vector3:
    return a * (1.0 - u - v) + b * u + c * v

func _append_refined(output: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3, portals: Array) -> int:
    var horizontal_max := maxf(Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z)),
        maxf(Vector2(a.x, a.z).distance_to(Vector2(c.x, c.z)),
        Vector2(b.x, b.z).distance_to(Vector2(c.x, c.z))))
    var steps := clampi(int(ceil(horizontal_max / COLLISION_DETAIL_M)), 1, 16)
    var removed := 0
    for i in range(steps):
        for j in range(steps - i):
            var u0 := float(i) / float(steps)
            var v0 := float(j) / float(steps)
            var u1 := float(i + 1) / float(steps)
            var v1 := float(j + 1) / float(steps)
            var p00 := _barycentric(a, b, c, u0, v0)
            var p10 := _barycentric(a, b, c, u1, v0)
            var p01 := _barycentric(a, b, c, u0, v1)
            if _centroid_in_portal(p00, p10, p01, portals):
                removed += 1
            else:
                output.append_array(PackedVector3Array([p00, p10, p01]))
            if i + j < steps - 1:
                var p11 := _barycentric(a, b, c, u1, v1)
                if _centroid_in_portal(p10, p11, p01, portals):
                    removed += 1
                else:
                    output.append_array(PackedVector3Array([p10, p11, p01]))
    return removed

func _carve_portal_collision(tile_root: Node3D, portals: Array) -> void:
    var collider := _terrain_collision(tile_root)
    if collider == null:
        return
    var shape := collider.shape as ConcavePolygonShape3D
    var faces := shape.get_faces()
    var rebuilt := PackedVector3Array()
    var removed := 0
    for cursor in range(0, faces.size(), 3):
        if cursor + 2 >= faces.size():
            break
        var a := faces[cursor]
        var b := faces[cursor + 1]
        var c := faces[cursor + 2]
        if _could_touch_portal(a, b, c, portals):
            removed += _append_refined(rebuilt, a, b, c, portals)
        else:
            rebuilt.append_array(PackedVector3Array([a, b, c]))
    if removed <= 0:
        return
    var replacement := ConcavePolygonShape3D.new()
    replacement.backface_collision = true
    replacement.set_faces(rebuilt)
    collider.shape = replacement
    collision_triangles_removed += removed

func _tunnel_material_instance() -> StandardMaterial3D:
    if _tunnel_material == null:
        _tunnel_material = StandardMaterial3D.new()
        _tunnel_material.albedo_color = Color(0.20, 0.205, 0.19)
        _tunnel_material.roughness = 0.92
        _tunnel_material.metallic = 0.0
    return _tunnel_material

func _add_box(body: StaticBody3D, dimensions: Vector3, center: Vector3) -> void:
    var mesh := BoxMesh.new()
    mesh.size = dimensions
    var instance := MeshInstance3D.new()
    instance.mesh = mesh
    instance.material_override = _tunnel_material_instance()
    instance.position = center
    body.add_child(instance)
    var shape := BoxShape3D.new()
    shape.size = dimensions
    var collider := CollisionShape3D.new()
    collider.shape = shape
    collider.position = center
    body.add_child(collider)

func _build_tunnel_shell(tile: Vector2i, tile_root: Node3D, tunnels: Array) -> void:
    var old := tile_root.get_node_or_null("TunnelShell")
    if old != null:
        tile_root.remove_child(old)
        old.queue_free()
    var shell := Node3D.new()
    shell.name = "TunnelShell"
    tile_root.add_child(shell)
    var origin := Vector2(float(tile.x) * float(terrain.tile_size), float(tile.y) * float(terrain.tile_size))
    for raw in tunnels:
        if not raw is Dictionary:
            continue
        var pa: Array = raw.get("a", [])
        var pb: Array = raw.get("b", [])
        if pa.size() < 3 or pb.size() < 3:
            continue
        var a := Vector3(float(pa[0]) - origin.x, float(pa[1]), float(pa[2]) - origin.y)
        var b := Vector3(float(pb[0]) - origin.x, float(pb[1]), float(pb[2]) - origin.y)
        var delta := b - a
        var length := delta.length()
        if length < 0.25:
            continue
        var forward := delta / length
        var right := Vector3.UP.cross(forward)
        if right.length_squared() < 0.0001:
            right = Vector3.RIGHT
        else:
            right = right.normalized()
        var up := forward.cross(right).normalized()
        var basis := Basis(right, up, forward)
        var body := StaticBody3D.new()
        body.name = "TunnelSegment_%d" % tunnel_segments_built
        body.transform = Transform3D(basis, (a + b) * 0.5)
        body.collision_layer = 1
        body.collision_mask = 0
        var clear_width := maxf(4.5, float(raw.get("width_m", 6.0)) + 1.2)
        var side_x := clear_width * 0.5 + WALL_THICKNESS_M * 0.5
        var wall_size := Vector3(WALL_THICKNESS_M, TUNNEL_CLEARANCE_M, length + 0.6)
        _add_box(body, wall_size, Vector3(-side_x, TUNNEL_CLEARANCE_M * 0.5, 0.0))
        _add_box(body, wall_size, Vector3(side_x, TUNNEL_CLEARANCE_M * 0.5, 0.0))
        _add_box(body, Vector3(clear_width + WALL_THICKNESS_M * 2.0,
            CEILING_THICKNESS_M, length + 0.6),
            Vector3(0.0, TUNNEL_CLEARANCE_M + CEILING_THICKNESS_M * 0.5, 0.0))
        shell.add_child(body)
        tunnel_segments_built += 1
