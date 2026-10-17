extends Node3D
class_name YardmanHydrologyGeometry

# Runtime replacement for open river/stream/canal corridors. The national DEM
# remains the geographic base, but its 64 m grid is too coarse to represent a
# narrow channel. The channel compiler therefore supplies a protected local
# corridor. Here we remove the coarse visual/collision skin only inside that
# corridor, then insert a higher-resolution bank/bed surface.

const CHANNEL_ROOT := "res://data/hydrology/channels"
const MASK_RESOLUTION := 1024
const COLLISION_DETAIL_M := 4.0
const REPLACEMENT_OVERLAP_M := 2.2

var terrain: Node
var channel_tiles_built := 0
var channel_fragments_built := 0
var collision_triangles_removed := 0
var _water_material: StandardMaterial3D

func _ready() -> void:
    call_deferred("_bind_terrain")

func _bind_terrain() -> void:
    terrain = get_parent().get_node_or_null("JamaicaTerrainStreamer")
    if terrain == null:
        await get_tree().process_frame
        terrain = get_parent().get_node_or_null("JamaicaTerrainStreamer")
    if terrain == null:
        push_error("Hydrology geometry helper could not find JamaicaTerrainStreamer")
        return
    if not terrain.tile_ready.is_connected(_on_terrain_tile_ready):
        terrain.tile_ready.connect(_on_terrain_tile_ready)

func _read_channels(tile: Vector2i) -> Array:
    var path := "%s/tiles/tile_%d_%d.json" % [CHANNEL_ROOT, tile.x, tile.y]
    if not FileAccess.file_exists(path):
        return []
    var payload = JSON.parse_string(FileAccess.get_file_as_string(path))
    if not payload is Dictionary:
        push_error("Invalid hydrology channel tile: " + path)
        return []
    var channels = payload.get("channels", [])
    return channels if channels is Array else []

func _on_terrain_tile_ready(tile: Vector2i) -> void:
    if terrain == null:
        return
    var channels := _read_channels(tile)
    if channels.is_empty():
        return
    var key: String = terrain._tile_key(tile.x, tile.y)
    var tile_root = terrain._loaded.get(key)
    if not tile_root is Node3D:
        return
    var prepared := _prepare_channels(tile, channels)
    if prepared.is_empty():
        return
    if not _apply_channel_mask(tile_root, prepared):
        # Never draw replacement water/banks over an intact terrain skin. That
        # would return to the pasted-on geometry this system exists to remove.
        push_error("Hydrology channel mask could not bind to registered land")
        return
    _carve_channel_collision(tile_root, prepared)
    _build_channel_mesh(tile_root, prepared)
    channel_tiles_built += 1
    channel_fragments_built += prepared.size()

func _prepare_channels(tile: Vector2i, channels: Array) -> Array:
    var result: Array = []
    var origin := Vector2(float(tile.x) * float(terrain.tile_size), float(tile.y) * float(terrain.tile_size))
    for raw in channels:
        if not raw is Dictionary:
            continue
        var pa = raw.get("a", [])
        var pb = raw.get("b", [])
        var right_raw = raw.get("right", [])
        var bed_raw = raw.get("bed_y", [])
        var water_raw = raw.get("water_y", [])
        var left_raw = raw.get("bank_left_y", [])
        var right_y_raw = raw.get("bank_right_y", [])
        if not pa is Array or not pb is Array or pa.size() < 3 or pb.size() < 3:
            continue
        if not right_raw is Array or right_raw.size() < 2:
            continue
        if not bed_raw is Array or bed_raw.size() < 2 or not water_raw is Array or water_raw.size() < 2:
            continue
        if not left_raw is Array or left_raw.size() < 2 or not right_y_raw is Array or right_y_raw.size() < 2:
            continue
        var a := Vector2(float(pa[0]) - origin.x, float(pa[2]) - origin.y)
        var b := Vector2(float(pb[0]) - origin.x, float(pb[2]) - origin.y)
        var right := Vector2(float(right_raw[0]), float(right_raw[1]))
        if right.length_squared() < 0.5 or a.distance_squared_to(b) < 0.01:
            continue
        right = right.normalized()
        var width := maxf(0.5, float(raw.get("width_m", 1.0)))
        var cut_half := maxf(width * 0.5 + 0.5, float(raw.get("cut_half_width_m", width * 0.5 + 2.5)))
        var minimum := Vector2(minf(a.x, b.x) - cut_half, minf(a.y, b.y) - cut_half)
        var maximum := Vector2(maxf(a.x, b.x) + cut_half, maxf(a.y, b.y) + cut_half)
        result.append({
            "id": str(raw.get("id", "")),
            "a": a, "b": b, "right": right,
            "width": width, "cut_half": cut_half,
            "bank_left": Vector2(float(left_raw[0]), float(left_raw[1])),
            "bank_right": Vector2(float(right_y_raw[0]), float(right_y_raw[1])),
            "bed": Vector2(float(bed_raw[0]), float(bed_raw[1])),
            "water": Vector2(float(water_raw[0]), float(water_raw[1])),
            "intermittent": bool(raw.get("intermittent", false)),
            "bounds": Rect2(minimum, maximum - minimum),
        })
    return result

func _distance_squared_to_segment(point: Vector2, a: Vector2, b: Vector2) -> float:
    var delta := b - a
    var length_squared := delta.length_squared()
    if length_squared <= 0.0000001:
        return point.distance_squared_to(a)
    var fraction := clampf((point - a).dot(delta) / length_squared, 0.0, 1.0)
    return point.distance_squared_to(a + delta * fraction)

func _inside_channel(point: Vector2, channels: Array) -> bool:
    for channel in channels:
        var bounds: Rect2 = channel["bounds"]
        if not bounds.has_point(point):
            continue
        var radius := float(channel["cut_half"])
        if _distance_squared_to_segment(point, channel["a"], channel["b"]) <= radius * radius:
            return true
    return false

func _apply_channel_mask(tile_root: Node3D, channels: Array) -> bool:
    var land := tile_root.get_node_or_null("RegisteredLand") as MeshInstance3D
    if land == null or land.mesh == null or land.mesh.get_surface_count() == 0:
        return false
    var material := land.mesh.surface_get_material(0) as ShaderMaterial
    if material == null:
        return false
    var image := Image.create(MASK_RESOLUTION, MASK_RESOLUTION, false, Image.FORMAT_R8)
    image.fill(Color(0, 0, 0, 1))
    var metres_per_pixel := float(terrain.tile_size) / float(MASK_RESOLUTION)
    for channel in channels:
        var bounds: Rect2 = channel["bounds"]
        var x0 := clampi(int(floor(bounds.position.x / metres_per_pixel)), 0, MASK_RESOLUTION - 1)
        var y0 := clampi(int(floor(bounds.position.y / metres_per_pixel)), 0, MASK_RESOLUTION - 1)
        var x1 := clampi(int(ceil(bounds.end.x / metres_per_pixel)), 0, MASK_RESOLUTION - 1)
        var y1 := clampi(int(ceil(bounds.end.y / metres_per_pixel)), 0, MASK_RESOLUTION - 1)
        var a: Vector2 = channel["a"]
        var b: Vector2 = channel["b"]
        var radius := float(channel["cut_half"])
        var radius_squared := radius * radius
        for py in range(y0, y1 + 1):
            for px in range(x0, x1 + 1):
                var point := Vector2((float(px) + 0.5) * metres_per_pixel,
                    (float(py) + 0.5) * metres_per_pixel)
                if _distance_squared_to_segment(point, a, b) <= radius_squared:
                    image.set_pixel(px, py, Color(1, 0, 0, 1))
    material.set_shader_parameter("hydrology_channel_mask", ImageTexture.create_from_image(image))
    material.set_shader_parameter("hydrology_channel_mask_enabled", true)
    material.set_shader_parameter("terrain_tile_size", float(terrain.tile_size))
    return true

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

func _could_touch_channel(a: Vector3, b: Vector3, c: Vector3, channels: Array) -> bool:
    var bounds := _triangle_bounds(a, b, c)
    for channel in channels:
        var channel_bounds: Rect2 = channel["bounds"]
        if bounds.intersects(channel_bounds, true):
            return true
    return false

func _centroid_inside_channel(a: Vector3, b: Vector3, c: Vector3, channels: Array) -> bool:
    var point := Vector2((a.x + b.x + c.x) / 3.0, (a.z + b.z + c.z) / 3.0)
    return _inside_channel(point, channels)

func _barycentric(a: Vector3, b: Vector3, c: Vector3, u: float, v: float) -> Vector3:
    return a * (1.0 - u - v) + b * u + c * v

func _append_refined(output: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3, channels: Array) -> int:
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
            if _centroid_inside_channel(p00, p10, p01, channels):
                removed += 1
            else:
                output.append_array(PackedVector3Array([p00, p10, p01]))
            if i + j < steps - 1:
                var p11 := _barycentric(a, b, c, u1, v1)
                if _centroid_inside_channel(p10, p11, p01, channels):
                    removed += 1
                else:
                    output.append_array(PackedVector3Array([p10, p11, p01]))
    return removed

func _carve_channel_collision(tile_root: Node3D, channels: Array) -> void:
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
        var a: Vector3 = faces[cursor]
        var b: Vector3 = faces[cursor + 1]
        var c: Vector3 = faces[cursor + 2]
        if _could_touch_channel(a, b, c, channels):
            removed += _append_refined(rebuilt, a, b, c, channels)
        else:
            rebuilt.append_array(PackedVector3Array([a, b, c]))
    if removed <= 0:
        return
    var replacement := ConcavePolygonShape3D.new()
    replacement.backface_collision = true
    replacement.set_faces(rebuilt)
    collider.shape = replacement
    collision_triangles_removed += removed

func _water_material_instance() -> StandardMaterial3D:
    if _water_material == null:
        _water_material = StandardMaterial3D.new()
        _water_material.albedo_color = Color(0.08, 0.25, 0.28, 0.72)
        _water_material.roughness = 0.16
        _water_material.metallic = 0.0
        _water_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
        _water_material.cull_mode = BaseMaterial3D.CULL_DISABLED
    return _water_material

func _emit_up_triangle(tool: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
    if (b - a).cross(c - a).y < 0.0:
        var swap := b
        b = c
        c = swap
    tool.add_vertex(a)
    tool.add_vertex(b)
    tool.add_vertex(c)

func _emit_up_quad(tool: SurfaceTool, a0: Vector3, a1: Vector3, b0: Vector3, b1: Vector3) -> void:
    _emit_up_triangle(tool, a0, b0, a1)
    _emit_up_triangle(tool, a1, b0, b1)

func _build_channel_mesh(tile_root: Node3D, channels: Array) -> void:
    var land := tile_root.get_node_or_null("RegisteredLand") as MeshInstance3D
    if land == null or land.mesh == null:
        return
    var bank_material: Material = land.mesh.surface_get_material(0)
    if bank_material != null:
        bank_material = bank_material.duplicate()
        if bank_material is ShaderMaterial:
            (bank_material as ShaderMaterial).set_shader_parameter("hydrology_channel_mask_enabled", false)
            (bank_material as ShaderMaterial).set_shader_parameter("tunnel_portal_mask_enabled", false)

    var bank_tool := SurfaceTool.new()
    bank_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
    if bank_material != null:
        bank_tool.set_material(bank_material)
    var water_tool := SurfaceTool.new()
    water_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
    water_tool.set_material(_water_material_instance())
    var water_triangles := 0

    for channel in channels:
        var a2: Vector2 = channel["a"]
        var b2: Vector2 = channel["b"]
        var right: Vector2 = channel["right"]
        var width := float(channel["width"])
        var outer := float(channel["cut_half"]) + REPLACEMENT_OVERLAP_M
        var bed_half := maxf(0.25, width * 0.5)
        var left_y: Vector2 = channel["bank_left"]
        var right_y: Vector2 = channel["bank_right"]
        var bed_y: Vector2 = channel["bed"]
        var water_y: Vector2 = channel["water"]

        var a_left_outer := Vector3(a2.x + right.x * outer, left_y.x, a2.y + right.y * outer)
        var a_left_bed := Vector3(a2.x + right.x * bed_half, bed_y.x, a2.y + right.y * bed_half)
        var a_right_bed := Vector3(a2.x - right.x * bed_half, bed_y.x, a2.y - right.y * bed_half)
        var a_right_outer := Vector3(a2.x - right.x * outer, right_y.x, a2.y - right.y * outer)
        var b_left_outer := Vector3(b2.x + right.x * outer, left_y.y, b2.y + right.y * outer)
        var b_left_bed := Vector3(b2.x + right.x * bed_half, bed_y.y, b2.y + right.y * bed_half)
        var b_right_bed := Vector3(b2.x - right.x * bed_half, bed_y.y, b2.y - right.y * bed_half)
        var b_right_outer := Vector3(b2.x - right.x * outer, right_y.y, b2.y - right.y * outer)

        _emit_up_quad(bank_tool, a_left_outer, a_left_bed, b_left_outer, b_left_bed)
        _emit_up_quad(bank_tool, a_left_bed, a_right_bed, b_left_bed, b_right_bed)
        _emit_up_quad(bank_tool, a_right_bed, a_right_outer, b_right_bed, b_right_outer)

        if not bool(channel["intermittent"]):
            var water_half := maxf(0.20, width * 0.46)
            var wa0 := Vector3(a2.x + right.x * water_half, water_y.x, a2.y + right.y * water_half)
            var wa1 := Vector3(a2.x - right.x * water_half, water_y.x, a2.y - right.y * water_half)
            var wb0 := Vector3(b2.x + right.x * water_half, water_y.y, b2.y + right.y * water_half)
            var wb1 := Vector3(b2.x - right.x * water_half, water_y.y, b2.y - right.y * water_half)
            _emit_up_quad(water_tool, wa0, wa1, wb0, wb1)
            water_triangles += 2

    bank_tool.generate_normals()
    var bank_mesh := bank_tool.commit()
    if bank_mesh == null or bank_mesh.get_surface_count() == 0:
        return
    var root := Node3D.new()
    root.name = "RegisteredHydrologyChannels"
    tile_root.add_child(root)

    var bank_instance := MeshInstance3D.new()
    bank_instance.name = "ChannelBanksAndBeds"
    bank_instance.mesh = bank_mesh
    root.add_child(bank_instance)

    var faces := bank_mesh.get_faces()
    if not faces.is_empty():
        var shape := ConcavePolygonShape3D.new()
        shape.backface_collision = true
        shape.set_faces(faces)
        var collider := CollisionShape3D.new()
        collider.shape = shape
        var body := StaticBody3D.new()
        body.name = "ChannelCollision"
        body.collision_layer = 1
        body.collision_mask = 0
        body.add_child(collider)
        root.add_child(body)

    if water_triangles > 0:
        water_tool.generate_normals()
        var water_mesh := water_tool.commit()
        if water_mesh != null and water_mesh.get_surface_count() > 0:
            var water_instance := MeshInstance3D.new()
            water_instance.name = "ChannelWater"
            water_instance.mesh = water_mesh
            root.add_child(water_instance)
