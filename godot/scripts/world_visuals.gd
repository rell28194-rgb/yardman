extends RefCounted
class_name YardmanWorldVisuals

const PROFILES := {
    "Performance": {"trees": 70, "road_radius": 1, "terrain_radius": 1, "shadows": false},
    "Balanced": {"trees": 140, "road_radius": 2, "terrain_radius": 1, "shadows": true},
    "Quality": {"trees": 220, "road_radius": 2, "terrain_radius": 2, "shadows": true},
    "Ultra": {"trees": 320, "road_radius": 3, "terrain_radius": 2, "shadows": true},
    "Custom": {"trees": 160, "road_radius": 2, "terrain_radius": 1, "shadows": true},
}
var quality := "Balanced"
var custom: Dictionary = {}
var _tree_mesh: ArrayMesh

func settings() -> Dictionary:
    var profile: Dictionary = PROFILES.get(quality, PROFILES.Balanced).duplicate()
    if quality == "Custom":
        profile.merge(custom, true)
    return profile

func make_vehicle(car: Node3D) -> void:
    var rig := Node3D.new()
    rig.name = "VisualRig"
    car.add_child(rig)
    var paint := _material(Color(0.045, 0.18, 0.24), 0.55, 0.25)
    var glass := _material(Color(0.10, 0.23, 0.29), 0.35, 0.15)
    var rubber := _material(Color(0.025, 0.028, 0.035), 0.0, 0.85)
    var silver := _material(Color(0.55, 0.59, 0.62), 0.8, 0.3)
    _box(rig, Vector3(1.85, 0.55, 4.0), Vector3(0, 0.65, 0), paint)
    _box(rig, Vector3(1.55, 0.65, 1.95), Vector3(0, 1.2, 0.20), glass)
    _box(rig, Vector3(1.58, 0.08, 2.00), Vector3(0, 1.57, 0.20), paint)
    _box(rig, Vector3(1.92, 0.16, 0.22), Vector3(0, 0.45, -1.96), rubber)
    _box(rig, Vector3(1.92, 0.16, 0.22), Vector3(0, 0.45, 1.96), rubber)
    for x in [-0.94, 0.94]:
        for z in [-1.32, 1.32]:
            _cylinder(rig, 0.34, 0.34, 0.20, Vector3(x, 0.34, z), rubber, Vector3(0, 0, PI * 0.5), 16)
            _cylinder(rig, 0.21, 0.21, 0.215, Vector3(x, 0.34, z), silver, Vector3(0, 0, PI * 0.5), 12)
    var headlight := _material(Color(1.0, 0.91, 0.67), 0.15, 0.25)
    var tail := _material(Color(0.72, 0.055, 0.03), 0.1, 0.25)
    for x in [-0.63, 0.63]:
        _box(rig, Vector3(0.40, 0.16, 0.045), Vector3(x, 0.78, -2.01), headlight)
        _box(rig, Vector3(0.32, 0.15, 0.045), Vector3(x, 0.78, 2.01), tail)
        _box(rig, Vector3(0.16, 0.10, 0.28), Vector3(signf(x) * 0.94, 1.12, -0.7), paint)
    _box(rig, Vector3(0.58, 0.14, 0.045), Vector3(0, 0.49, 2.08), _material(Color(0.9, 0.84, 0.55), 0.0, 0.6))

func _material(color: Color, metal: float, rough: float) -> StandardMaterial3D:
    var material := StandardMaterial3D.new()
    material.albedo_color = color
    material.metallic = metal
    material.roughness = rough
    return material

func _box(parent: Node3D, dimensions: Vector3, center: Vector3, material: Material) -> void:
    var mesh := BoxMesh.new()
    mesh.size = dimensions
    var instance := MeshInstance3D.new()
    instance.mesh = mesh
    instance.position = center
    instance.material_override = material
    parent.add_child(instance)

func _cylinder(parent: Node3D, top: float, bottom: float, height: float, center: Vector3, material: Material, rotation_local: Vector3 = Vector3.ZERO, sides: int = 10) -> void:
    var mesh := CylinderMesh.new()
    mesh.top_radius = top
    mesh.bottom_radius = bottom
    mesh.height = height
    mesh.radial_segments = sides
    var instance := MeshInstance3D.new()
    instance.mesh = mesh
    instance.position = center
    instance.rotation = rotation_local
    instance.material_override = material
    parent.add_child(instance)

func make_roadside(root: Node3D, segments: Array, tile: Vector2i, tile_size: float) -> void:
    if root.has_node("RoadsideProxy"):
        root.get_node("RoadsideProxy").queue_free()
    var transforms: Array[Transform3D] = []
    # Keep one deterministic prefix for every tier; switching density changes
    # visible instance count without regenerating or moving existing props.
    var limit := 400
    var seen: Dictionary = {}
    for segment in segments:
        if segment.size() < 12 or transforms.size() >= limit:
            continue
        var seed_text := str(segment[7]) + ":" + str(segment[8])
        if seen.has(seed_text):
            continue
        seen[seed_text] = true
        var seed_value := seed_text.hash() & 0x7fffffff
        if seed_value % 23 != 0:
            continue
        var a := Vector2(float(segment[0]), float(segment[1]))
        var b := Vector2(float(segment[2]), float(segment[3]))
        var midpoint := (a + b) * 0.5
        var direction := (b - a).normalized()
        var side := -1.0 if seed_value % 2 == 0 else 1.0
        var position_world := midpoint + Vector2(-direction.y, direction.x) * (float(segment[4]) * 0.5 + 5.0 + float(seed_value % 13)) * side
        if int(floor(position_world.x / tile_size)) != tile.x or int(floor(position_world.y / tile_size)) != tile.y:
            continue
        var scale_value := 0.75 + float(seed_value % 100) / 180.0
        var basis := Basis(Vector3.UP, float(seed_value % 628) / 100.0).scaled(Vector3.ONE * scale_value)
        var local := Vector3(position_world.x - float(tile.x) * tile_size,
            (float(segment[9]) + float(segment[10])) * 0.5,
            position_world.y - float(tile.y) * tile_size)
        transforms.append(Transform3D(basis, local))
    if transforms.is_empty():
        return
    if _tree_mesh == null:
        _tree_mesh = _make_tree_mesh()
    var multi := MultiMesh.new()
    multi.transform_format = MultiMesh.TRANSFORM_3D
    multi.mesh = _tree_mesh
    multi.instance_count = transforms.size()
    multi.visible_instance_count = mini(clampi(int(settings().trees), 40, 400), transforms.size())
    for i in range(transforms.size()):
        multi.set_instance_transform(i, transforms[i])
    var instance := MultiMeshInstance3D.new()
    instance.name = "RoadsideProxy"
    instance.multimesh = multi
    instance.visibility_range_end = 1400.0
    root.add_child(instance)

func _make_tree_mesh() -> ArrayMesh:
    var surface := SurfaceTool.new()
    surface.begin(Mesh.PRIMITIVE_TRIANGLES)
    _cone(surface, 0.12, 0.28, 7.5, 3.75, Color(0.34, 0.24, 0.14), 8)
    for angle_index in range(8):
        var angle := float(angle_index) * TAU / 8.0
        var end := Vector3(cos(angle) * 3.8, 6.5, sin(angle) * 3.8)
        var crown := Vector3(0, 7.8, 0)
        var side := Vector3(-sin(angle), 0, cos(angle)) * 0.48
        surface.set_color(Color(0.12 + float(angle_index % 2) * 0.07, 0.36, 0.13))
        for vertex in [crown, end - side, end + side]:
            surface.add_vertex(vertex)
        for vertex in [crown, end + side, end - side]:
            surface.add_vertex(vertex)
    surface.generate_normals()
    var mesh := surface.commit()
    var material := StandardMaterial3D.new()
    material.vertex_color_use_as_albedo = true
    material.roughness = 0.9
    material.cull_mode = BaseMaterial3D.CULL_DISABLED
    mesh.surface_set_material(0, material)
    return mesh

func _cone(surface: SurfaceTool, top: float, bottom: float, height: float, cy: float, color: Color, sides: int) -> void:
    surface.set_color(color)
    for i in range(sides):
        var angle_a := float(i) * TAU / float(sides)
        var angle_b := float(i + 1) * TAU / float(sides)
        var a := Vector3(cos(angle_a) * bottom, cy - height * 0.5, sin(angle_a) * bottom)
        var b := Vector3(cos(angle_b) * bottom, cy - height * 0.5, sin(angle_b) * bottom)
        var c := Vector3(cos(angle_a) * top, cy + height * 0.5, sin(angle_a) * top)
        var d := Vector3(cos(angle_b) * top, cy + height * 0.5, sin(angle_b) * top)
        for vertex in [a, b, c, b, d, c]:
            surface.add_vertex(vertex)
