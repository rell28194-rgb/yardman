extends Node3D
class_name YardmanRoadEarthworkGeometry

# High-confidence road earthworks only. Runtime data is emitted exclusively from
# explicit OSM cutting/embankment tags that the DEM can physically support.
# DEM-only review candidates never enter this system.

const EARTHWORK_ROOT := "res://data/earthworks/geometry"
const MASK_RESOLUTION := 1024
const COLLISION_DETAIL_M := 4.0
const ROAD_SEAM_DROP_M := 0.04

var terrain: Node
var earthwork_tiles_built := 0
var earthwork_fragments_built := 0
var collision_triangles_removed := 0

func _ready() -> void:
    call_deferred("_bind_terrain")

func _bind_terrain() -> void:
    terrain = get_parent().get_node_or_null("JamaicaTerrainStreamer")
    if terrain == null:
        await get_tree().process_frame
        terrain = get_parent().get_node_or_null("JamaicaTerrainStreamer")
    if terrain == null:
        push_error("Road earthwork helper could not find JamaicaTerrainStreamer")
        return
    if not terrain.tile_ready.is_connected(_on_terrain_tile_ready):
        terrain.tile_ready.connect(_on_terrain_tile_ready)

func _read_records(tile: Vector2i) -> Array:
    var path := "%s/tiles/tile_%d_%d.json" % [EARTHWORK_ROOT, tile.x, tile.y]
    if not FileAccess.file_exists(path):
        return []
    var payload = JSON.parse_string(FileAccess.get_file_as_string(path))
    if not payload is Dictionary:
        push_error("Invalid road earthwork geometry tile: " + path)
        return []
    var records = payload.get("earthworks", [])
    return records if records is Array else []

func _on_terrain_tile_ready(tile: Vector2i) -> void:
    if terrain == null:
        return
    var records := _read_records(tile)
    if records.is_empty():
        return
    var key: String = terrain._tile_key(tile.x, tile.y)
    var tile_root = terrain._loaded.get(key)
    if not tile_root is Node3D:
        return
    var prepared := _prepare_records(tile, records)
    if prepared.is_empty():
        return
    if not _apply_mask(tile_root, prepared):
        push_error("Road earthwork mask could not bind to registered terrain")
        return
    _carve_collision(tile_root, prepared)
    _build_replacement_mesh(tile_root, prepared)
    earthwork_tiles_built += 1
    earthwork_fragments_built += prepared.size()

func _prepare_records(tile: Vector2i, records: Array) -> Array:
    var result: Array = []
    var origin := Vector2(float(tile.x) * float(terrain.tile_size), float(tile.y) * float(terrain.tile_size))
    for raw in records:
        if not raw is Dictionary:
            continue
        var classification := str(raw.get("classification", ""))
        if classification not in ["source_cutting", "source_embankment"]:
            continue
        var pa = raw.get("a", [])
        var pb = raw.get("b", [])
        var right_raw = raw.get("right", [])
        var left_raw = raw.get("outer_left_y", [])
        var right_y_raw = raw.get("outer_right_y", [])
        if not pa is Array or not pb is Array or pa.size() < 3 or pb.size() < 3:
            continue
        if not right_raw is Array or right_raw.size() < 2:
            continue
        if not left_raw is Array or left_raw.size() < 2 or not right_y_raw is Array or right_y_raw.size() < 2:
            continue
        var a := Vector2(float(pa[0]) - origin.x, float(pa[2]) - origin.y)
        var b := Vector2(float(pb[0]) - origin.x, float(pb[2]) - origin.y)
        var right := Vector2(float(right_raw[0]), float(right_raw[1]))
        if right.length_squared() < 0.5 or a.distance_squared_to(b) < 0.01:
            continue
        right = right.normalized()
        var road_half := maxf(0.75, float(raw.get("road_half_width_m", 3.5)))
        var outer_half := maxf(road_half + 1.0, float(raw.get("outer_half_width_m", road_half + 4.0)))
        var mask_half := maxf(outer_half, float(raw.get("mask_half_width_m", outer_half + 1.0)))
        var minimum := Vector2(minf(a.x, b.x) - mask_half, minf(a.y, b.y) - mask_half)
        var maximum := Vector2(maxf(a.x, b.x) + mask_half, maxf(a.y, b.y) + mask_half)
        result.append({
            "id": str(raw.get("id", "")),
            "classification": classification,
            "a": a,
            "b": b,
            "a_y": float(pa[1]) - ROAD_SEAM_DROP_M,
            "b_y": float(pb[1]) - ROAD_SEAM_DROP_M,
            "right": right,
            "road_half": road_half,
            "outer_half": outer_half,
            "mask_half": mask_half,
            "outer_left_y": Vector2(float(left_raw[0]), float(left_raw[1])),
            "outer_right_y": Vector2(float(right_y_raw[0]), float(right_y_raw[1])),
            "bounds": Rect2(minimum, maximum - minimum),
        })
    return result

func _distance_squared_to_segment(point: Vector2, a: Vector2, b: Vector2) -> float:
    var delta := b - a
    var length_squared := delta.length_squared()
    if length_squared <= 0.0000001:
        return point.distance_squared_to(a)
    var t := clampf((point - a).dot(delta) / length_squared, 0.0, 1.0)
    return point.distance_squared_to(a + delta * t)

func _inside_any(point: Vector2, records: Array) -> bool:
    for record in records:
        var bounds: Rect2 = record["bounds"]
        if not bounds.has_point(point):
            continue
        var radius := float(record["mask_half"])
        if _distance_squared_to_segment(point, record["a"], record["b"]) <= radius * radius:
            return true
    return false

func _apply_mask(tile_root: Node3D, records: Array) -> bool:
    var land := tile_root.get_node_or_null("RegisteredLand") as MeshInstance3D
    if land == null or land.mesh == null or land.mesh.get_surface_count() == 0:
        return false
    var material := land.mesh.surface_get_material(0) as ShaderMaterial
    if material == null:
        return false
    var image := Image.create(MASK_RESOLUTION, MASK_RESOLUTION, false, Image.FORMAT_R8)
    image.fill(Color(0, 0, 0, 1))
    var metres_per_pixel := float(terrain.tile_size) / float(MASK_RESOLUTION)
    for record in records:
        var bounds: Rect2 = record["bounds"]
        var x0 := clampi(int(floor(bounds.position.x / metres_per_pixel)), 0, MASK_RESOLUTION - 1)
        var y0 := clampi(int(floor(bounds.position.y / metres_per_pixel)), 0, MASK_RESOLUTION - 1)
        var x1 := clampi(int(ceil(bounds.end.x / metres_per_pixel)), 0, MASK_RESOLUTION - 1)
        var y1 := clampi(int(ceil(bounds.end.y / metres_per_pixel)), 0, MASK_RESOLUTION - 1)
        var a: Vector2 = record["a"]
        var b: Vector2 = record["b"]
        var radius := float(record["mask_half"])
        var radius_squared := radius * radius
        for py in range(y0, y1 + 1):
            for px in range(x0, x1 + 1):
                var point := Vector2((float(px) + 0.5) * metres_per_pixel,
                    (float(py) + 0.5) * metres_per_pixel)
                if _distance_squared_to_segment(point, a, b) <= radius_squared:
                    image.set_pixel(px, py, Color(1, 0, 0, 1))
    material.set_shader_parameter("road_earthwork_mask", ImageTexture.create_from_image(image))
    material.set_shader_parameter("road_earthwork_mask_enabled", true)
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

func _could_touch(a: Vector3, b: Vector3, c: Vector3, records: Array) -> bool:
    var bounds := _triangle_bounds(a, b, c)
    for record in records:
        var earthwork_bounds: Rect2 = record["bounds"]
        if bounds.intersects(earthwork_bounds, true):
            return true
    return false

func _centroid_inside(a: Vector3, b: Vector3, c: Vector3, records: Array) -> bool:
    var point := Vector2((a.x + b.x + c.x) / 3.0, (a.z + b.z + c.z) / 3.0)
    return _inside_any(point, records)

func _barycentric(a: Vector3, b: Vector3, c: Vector3, u: float, v: float) -> Vector3:
    return a * (1.0 - u - v) + b * u + c * v

func _append_refined(output: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3, records: Array) -> int:
    var horizontal_max := maxf(Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z)),
        maxf(Vector2(a.x, a.z).distance_to(Vector2(c.x, c.z)), Vector2(b.x, b.z).distance_to(Vector2(c.x, c.z))))
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
            if _centroid_inside(p00, p10, p01, records):
                removed += 1
            else:
                output.append_array(PackedVector3Array([p00, p10, p01]))
            if i + j < steps - 1:
                var p11 := _barycentric(a, b, c, u1, v1)
                if _centroid_inside(p10, p11, p01, records):
                    removed += 1
                else:
                    output.append_array(PackedVector3Array([p10, p11, p01]))
    return removed

func _carve_collision(tile_root: Node3D, records: Array) -> void:
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
        if _could_touch(a, b, c, records):
            removed += _append_refined(rebuilt, a, b, c, records)
        else:
            rebuilt.append_array(PackedVector3Array([a, b, c]))
    if removed <= 0:
        return
    var replacement := ConcavePolygonShape3D.new()
    replacement.backface_collision = true
    replacement.set_faces(rebuilt)
    collider.shape = replacement
    collision_triangles_removed += removed

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

func _build_replacement_mesh(tile_root: Node3D, records: Array) -> void:
    var land := tile_root.get_node_or_null("RegisteredLand") as MeshInstance3D
    if land == null or land.mesh == null or land.mesh.get_surface_count() == 0:
        return
    var material: Material = land.mesh.surface_get_material(0)
    if material != null:
        material = material.duplicate()
        if material is ShaderMaterial:
            # Preserve tunnel/hydrology masks on the replacement slopes but do
            # not let the earthwork mask discard the earthwork replacement itself.
            (material as ShaderMaterial).set_shader_parameter("road_earthwork_mask_enabled", false)

    var tool := SurfaceTool.new()
    tool.begin(Mesh.PRIMITIVE_TRIANGLES)
    if material != null:
        tool.set_material(material)

    for record in records:
        var a: Vector2 = record["a"]
        var b: Vector2 = record["b"]
        var right: Vector2 = record["right"]
        var road_half := float(record["road_half"])
        var outer_half := float(record["outer_half"])
        var left_outer_y: Vector2 = record["outer_left_y"]
        var right_outer_y: Vector2 = record["outer_right_y"]
        var a_y := float(record["a_y"])
        var b_y := float(record["b_y"])

        var a_left_outer := Vector3(a.x + right.x * outer_half, left_outer_y.x, a.y + right.y * outer_half)
        var a_left_edge := Vector3(a.x + right.x * road_half, a_y, a.y + right.y * road_half)
        var a_right_edge := Vector3(a.x - right.x * road_half, a_y, a.y - right.y * road_half)
        var a_right_outer := Vector3(a.x - right.x * outer_half, right_outer_y.x, a.y - right.y * outer_half)
        var b_left_outer := Vector3(b.x + right.x * outer_half, left_outer_y.y, b.y + right.y * outer_half)
        var b_left_edge := Vector3(b.x + right.x * road_half, b_y, b.y + right.y * road_half)
        var b_right_edge := Vector3(b.x - right.x * road_half, b_y, b.y - right.y * road_half)
        var b_right_outer := Vector3(b.x - right.x * outer_half, right_outer_y.y, b.y - right.y * outer_half)

        _emit_up_quad(tool, a_left_outer, a_left_edge, b_left_outer, b_left_edge)
        _emit_up_quad(tool, a_right_edge, a_right_outer, b_right_edge, b_right_outer)

    tool.generate_normals()
    var mesh := tool.commit()
    if mesh == null or mesh.get_surface_count() == 0:
        return
    var root := Node3D.new()
    root.name = "RegisteredRoadEarthworks"
    tile_root.add_child(root)
    var instance := MeshInstance3D.new()
    instance.name = "RoadCutFillSlopes"
    instance.mesh = mesh
    root.add_child(instance)

    var faces := mesh.get_faces()
    if not faces.is_empty():
        var shape := ConcavePolygonShape3D.new()
        shape.backface_collision = true
        shape.set_faces(faces)
        var collider := CollisionShape3D.new()
        collider.shape = shape
        var body := StaticBody3D.new()
        body.name = "RoadEarthworkCollision"
        body.collision_layer = 1
        body.collision_mask = 0
        body.add_child(collider)
        root.add_child(body)
