extends Node3D
class_name YardmanVehicleModel

# Original procedural 4.3 m compact sedan. No reference-game mesh, texture,
# branding or proprietary art is copied into the build.
var shell: Node3D
var front_pivots: Array[Node3D] = []
var wheels: Array[Node3D] = []
var brake_material: StandardMaterial3D
var reverse_material: StandardMaterial3D
var _wheel_rotation := 0.0
var _paint: StandardMaterial3D
var _trim: StandardMaterial3D
var _glass: StandardMaterial3D
var _silver: StandardMaterial3D

func build() -> void:
    if shell != null:
        return
    _paint = _material(Color(0.14, 0.31, 0.37), 0.52, 0.27)
    _trim = _material(Color(0.024, 0.032, 0.037), 0.15, 0.62)
    _glass = _material(Color(0.055, 0.125, 0.16), 0.40, 0.13)
    _silver = _material(Color(0.54, 0.58, 0.62), 0.82, 0.25)
    shell = Node3D.new()
    shell.name = "BodyShell"
    add_child(shell)
    _make_body()
    _make_cabin()
    _make_details()
    _make_wheels()
    # Detail is authored as small parts for maintainability, then baked by
    # material into a few draws. Wheel pivots remain independent for animation.
    _batch_meshes(shell)
    for wheel in wheels:
        _batch_meshes(wheel)

func update_motion(delta: float, speed: float, steering: float, braking: float, reversing: bool, running: bool, pitch: float, roll: float) -> void:
    if shell == null:
        return
    _wheel_rotation = fmod(_wheel_rotation - speed * delta / 0.35, TAU)
    for wheel in wheels:
        wheel.rotation.x = _wheel_rotation
    for pivot in front_pivots:
        pivot.rotation.y = steering
    var response := 1.0 - exp(-delta * 8.0)
    shell.rotation.x = lerpf(shell.rotation.x, pitch, response)
    shell.rotation.z = lerpf(shell.rotation.z, roll, response)
    shell.position.y = lerpf(shell.position.y, -minf(absf(roll) * 0.12, 0.018), response)
    brake_material.emission_energy_multiplier = 2.0 if braking > 0.05 else (0.35 if running else 0.0)
    reverse_material.emission_energy_multiplier = 1.4 if reversing else 0.0

func _make_body() -> void:
    # Profiled hood, shoulders and trunk form a silhouette independent of the
    # side panels; the panels have actual tyre-arch cutouts.
    var rings := [
        Vector4(-2.15, 0.78, 0.43, 0.75), Vector4(-1.88, 0.90, 0.38, 0.86),
        Vector4(-1.36, 0.93, 0.38, 0.93), Vector4(-0.88, 0.93, 0.38, 0.96),
        Vector4(0.84, 0.93, 0.38, 0.96), Vector4(1.40, 0.93, 0.38, 0.92),
        Vector4(1.90, 0.88, 0.38, 0.85), Vector4(2.12, 0.76, 0.43, 0.76),
    ]
    var surface := SurfaceTool.new()
    surface.begin(Mesh.PRIMITIVE_TRIANGLES)
    for i in range(rings.size() - 1):
        var a: Vector4 = rings[i]
        var b: Vector4 = rings[i + 1]
        for sign_value in [-1.0, 1.0]:
            _quad(surface, Vector3(0, a.w + 0.035, a.x), Vector3(sign_value * a.y * 0.84, a.w, a.x), Vector3(sign_value * b.y * 0.84, b.w, b.x), Vector3(0, b.w + 0.035, b.x), Vector3.UP)
            _quad(surface, Vector3(sign_value * a.y * 0.84, a.w, a.x), Vector3(sign_value * a.y, a.w - 0.075, a.x), Vector3(sign_value * b.y, b.w - 0.075, b.x), Vector3(sign_value * b.y * 0.84, b.w, b.x), Vector3(sign_value, 0.5, 0))
    var front: Vector4 = rings[0]
    var back: Vector4 = rings[rings.size() - 1]
    _quad(surface, Vector3(-front.y, front.z, front.x), Vector3(front.y, front.z, front.x), Vector3(front.y, front.w - 0.06, front.x), Vector3(-front.y, front.w - 0.06, front.x), Vector3.FORWARD)
    _quad(surface, Vector3(-back.y, back.z, back.x), Vector3(-back.y, back.w - 0.06, back.x), Vector3(back.y, back.w - 0.06, back.x), Vector3(back.y, back.z, back.x), Vector3.BACK)
    _finish(surface, shell, _paint, "HoodAndTrunk")
    var outline := PackedVector2Array([
        Vector2(-2.15, 0.68), Vector2(-1.88, 0.785), Vector2(-1.36, 0.855), Vector2(-0.88, 0.885),
        Vector2(0.84, 0.885), Vector2(1.40, 0.845), Vector2(1.90, 0.775), Vector2(2.12, 0.70), Vector2(2.12, 0.43),
    ])
    for arch_z in [1.28, -1.28]:
        for segment in range(19):
            var theta := PI * float(segment) / 18.0
            outline.append(Vector2(arch_z + cos(theta) * 0.445, 0.35 + sin(theta) * 0.445))
    outline.append(Vector2(-2.15, 0.43))
    var indices := Geometry2D.triangulate_polygon(outline)
    for sign_value in [-1.0, 1.0]:
        var side_surface := SurfaceTool.new()
        side_surface.begin(Mesh.PRIMITIVE_TRIANGLES)
        for index in range(0, indices.size(), 3):
            var points: Array[Vector3] = []
            for vertex_index in range(3):
                var point := outline[indices[index + vertex_index]]
                var width := 0.93 - maxf(absf(point.x) - 1.60, 0.0) * 0.31
                points.append(Vector3(sign_value * width, point.y, point.x))
            _triangle(side_surface, points[0], points[1], points[2], Vector3(sign_value, 0, 0))
        _finish(side_surface, shell, _paint, "SidePanel")
        for arch_z in [-1.28, 1.28]:
            _arch(shell, sign_value * 0.938, arch_z, _trim)
        _box(shell, Vector3(0.025, 0.06, 1.75), Vector3(sign_value * 0.945, 0.45, 0.02), _trim)
        _beam(shell, Vector3(sign_value * 0.935, 0.49, 0.12), Vector3(sign_value * 0.935, 0.91, 0.12), 0.012, _trim)
        for handle_z in [-0.34, 0.55]:
            _box(shell, Vector3(0.023, 0.035, 0.15), Vector3(sign_value * 0.948, 0.85, handle_z), _silver)

func _make_cabin() -> void:
    var front_bottom := Vector3(0.80, 0.975, -0.95)
    var front_roof := Vector3(0.65, 1.485, -0.48)
    var rear_roof := Vector3(0.66, 1.485, 0.77)
    var rear_bottom := Vector3(0.80, 0.975, 1.19)
    var glass_surface := SurfaceTool.new()
    glass_surface.begin(Mesh.PRIMITIVE_TRIANGLES)
    _quad(glass_surface, Vector3(-front_bottom.x, front_bottom.y, front_bottom.z), front_bottom, front_roof, Vector3(-front_roof.x, front_roof.y, front_roof.z), Vector3(0, 0.5, -1))
    _quad(glass_surface, rear_bottom, Vector3(-rear_bottom.x, rear_bottom.y, rear_bottom.z), Vector3(-rear_roof.x, rear_roof.y, rear_roof.z), rear_roof, Vector3(0, 0.5, 1))
    for sign_value in [-1.0, 1.0]:
        _quad(glass_surface, Vector3(sign_value * front_bottom.x, front_bottom.y, front_bottom.z), Vector3(sign_value * rear_bottom.x, rear_bottom.y, rear_bottom.z), Vector3(sign_value * rear_roof.x, rear_roof.y, rear_roof.z), Vector3(sign_value * front_roof.x, front_roof.y, front_roof.z), Vector3(sign_value, 0.2, 0))
        _beam(shell, Vector3(sign_value * front_bottom.x, front_bottom.y, front_bottom.z), Vector3(sign_value * front_roof.x, front_roof.y, front_roof.z), 0.065, _paint)
        _beam(shell, Vector3(sign_value * rear_bottom.x, rear_bottom.y, rear_bottom.z), Vector3(sign_value * rear_roof.x, rear_roof.y, rear_roof.z), 0.085, _paint)
        _beam(shell, Vector3(sign_value * 0.80, 1.0, 0.14), Vector3(sign_value * 0.655, 1.485, 0.14), 0.053, _trim)
        _beam(shell, Vector3(sign_value * front_bottom.x, front_bottom.y, front_bottom.z), Vector3(sign_value * rear_bottom.x, rear_bottom.y, rear_bottom.z), 0.033, _silver)
        _beam(shell, Vector3(sign_value * front_roof.x, front_roof.y, front_roof.z), Vector3(sign_value * rear_roof.x, rear_roof.y, rear_roof.z), 0.042, _trim)
    _finish(glass_surface, shell, _glass, "TintedWindows")
    var roof_surface := SurfaceTool.new()
    roof_surface.begin(Mesh.PRIMITIVE_TRIANGLES)
    for sign_value in [-1.0, 1.0]:
        _quad(roof_surface, Vector3(0, 1.535, -0.45), Vector3(sign_value * 0.655, 1.505, -0.45), Vector3(sign_value * 0.665, 1.505, 0.75), Vector3(0, 1.535, 0.75), Vector3.UP)
    _finish(roof_surface, shell, _paint, "CrownedRoof")
    for x in [-0.37, 0.32]:
        _beam(shell, Vector3(x - 0.20, 1.011, -0.93), Vector3(x + 0.22, 1.06, -0.888), 0.013, _trim)
    for y in [1.12, 1.24, 1.36]:
        var z := lerpf(1.19, 0.77, (y - 0.975) / 0.51)
        _beam(shell, Vector3(-0.62, y, z + 0.004), Vector3(0.62, y, z + 0.004), 0.004, _silver)

func _make_details() -> void:
    _box(shell, Vector3(1.76, 0.12, 0.10), Vector3(0, 0.43, -2.13), _trim)
    _box(shell, Vector3(1.72, 0.11, 0.10), Vector3(0, 0.43, 2.12), _trim)
    _box(shell, Vector3(0.74, 0.19, 0.038), Vector3(0, 0.59, -2.163), _trim)
    for i in range(5):
        _box(shell, Vector3(0.69, 0.013, 0.048), Vector3(0, 0.526 + float(i) * 0.031, -2.167), _silver)
    var headlight := _material(Color(0.92, 0.91, 0.78), 0.12, 0.14)
    headlight.emission_enabled = true
    headlight.emission = Color(1.0, 0.89, 0.64)
    headlight.emission_energy_multiplier = 0.7
    brake_material = _material(Color(0.42, 0.025, 0.018), 0.15, 0.23)
    brake_material.emission_enabled = true
    brake_material.emission = Color(1.0, 0.05, 0.02)
    reverse_material = _material(Color(0.75, 0.77, 0.73), 0.12, 0.25)
    reverse_material.emission_enabled = true
    reverse_material.emission = Color(0.93, 0.94, 0.86)
    var amber := _material(Color(0.87, 0.36, 0.03), 0.12, 0.22)
    for sign_value in [-1.0, 1.0]:
        _box(shell, Vector3(0.38, 0.14, 0.049), Vector3(sign_value * 0.58, 0.65, -2.161), headlight)
        _box(shell, Vector3(0.082, 0.13, 0.052), Vector3(sign_value * 0.79, 0.65, -2.143), amber)
        _box(shell, Vector3(0.42, 0.14, 0.049), Vector3(sign_value * 0.54, 0.655, 2.13), brake_material)
        _box(shell, Vector3(0.11, 0.055, 0.053), Vector3(sign_value * 0.40, 0.637, 2.137), reverse_material)
        _beam(shell, Vector3(sign_value * 0.81, 1.025, -0.73), Vector3(sign_value * 1.015, 1.085, -0.70), 0.040, _trim)
        _box(shell, Vector3(0.19, 0.105, 0.235), Vector3(sign_value * 1.055, 1.10, -0.72), _paint)
        _box(shell, Vector3(0.16, 0.075, 0.014), Vector3(sign_value * 1.055, 1.10, -0.595), _silver)
    _box(shell, Vector3(0.42, 0.055, 0.035), Vector3(0, 1.005, 1.17), brake_material)
    var plate := _material(Color(0.89, 0.88, 0.71), 0.0, 0.53)
    for z in [-2.193, 2.162]:
        _box(shell, Vector3(0.42, 0.11, 0.026), Vector3(0, 0.42, z), plate)
        for index in range(5):
            _box(shell, Vector3(0.017, 0.048, 0.028), Vector3(-0.12 + index * 0.058, 0.42, z + signf(z) * 0.014), _trim)
    _cylinder(shell, 0.055, 0.12, Vector3(0.59, 0.31, 2.075), _silver, Vector3(PI * 0.5, 0, 0), 16)

func _make_wheels() -> void:
    var rubber := _material(Color(0.023, 0.025, 0.027), 0.0, 0.87)
    var disc := _material(Color(0.18, 0.19, 0.20), 0.65, 0.44)
    for x in [-0.95, 0.95]:
        for z in [-1.28, 1.28]:
            var pivot := Node3D.new()
            pivot.name = "FrontWheelPivot" if z < 0.0 else "RearWheelPivot"
            pivot.position = Vector3(x, 0.35, z)
            add_child(pivot)
            if z < 0.0:
                front_pivots.append(pivot)
            var spin := Node3D.new()
            spin.name = "WheelSpin"
            pivot.add_child(spin)
            wheels.append(spin)
            _cylinder(spin, 0.35, 0.22, Vector3.ZERO, rubber, Vector3(0, 0, PI * 0.5), 32)
            _cylinder(spin, 0.24, 0.235, Vector3.ZERO, _trim, Vector3(0, 0, PI * 0.5), 24)
            var outside := signf(x) * 0.128
            _cylinder(spin, 0.205, 0.025, Vector3(outside * 0.75, 0, 0), disc, Vector3(0, 0, PI * 0.5), 24)
            _cylinder(spin, 0.065, 0.265, Vector3.ZERO, _silver, Vector3(0, 0, PI * 0.5), 16)
            for spoke in range(5):
                var angle := TAU * float(spoke) / 5.0
                _beam(spin, Vector3(outside, cos(angle) * 0.052, sin(angle) * 0.052), Vector3(outside, cos(angle) * 0.222, sin(angle) * 0.222), 0.042, _silver)
            var rim := SurfaceTool.new()
            rim.begin(Mesh.PRIMITIVE_TRIANGLES)
            for segment in range(32):
                var a := TAU * float(segment) / 32.0
                var b := TAU * float(segment + 1) / 32.0
                _quad(rim, Vector3(outside, cos(a) * 0.216, sin(a) * 0.216), Vector3(outside, cos(a) * 0.247, sin(a) * 0.247), Vector3(outside, cos(b) * 0.247, sin(b) * 0.247), Vector3(outside, cos(b) * 0.216, sin(b) * 0.216), Vector3(signf(x), 0, 0))
            _finish(rim, spin, _silver, "RimRing")

func _arch(parent: Node3D, x: float, z: float, material: Material) -> void:
    var surface := SurfaceTool.new()
    surface.begin(Mesh.PRIMITIVE_TRIANGLES)
    for segment in range(24):
        var a := PI * float(segment) / 24.0
        var b := PI * float(segment + 1) / 24.0
        _quad(surface, Vector3(x, 0.35 + sin(a) * 0.439, z + cos(a) * 0.439), Vector3(x, 0.35 + sin(a) * 0.463, z + cos(a) * 0.463), Vector3(x, 0.35 + sin(b) * 0.463, z + cos(b) * 0.463), Vector3(x, 0.35 + sin(b) * 0.439, z + cos(b) * 0.439), Vector3(signf(x), 0, 0))
    _finish(surface, parent, material, "WheelArchTrim")

func _material(color: Color, metal: float, rough: float) -> StandardMaterial3D:
    var result := StandardMaterial3D.new()
    result.albedo_color = color
    result.metallic = metal
    result.roughness = rough
    return result

func _box(parent: Node3D, dimensions: Vector3, centre: Vector3, material: Material) -> MeshInstance3D:
    var mesh := BoxMesh.new()
    mesh.size = dimensions
    var instance := MeshInstance3D.new()
    instance.mesh = mesh
    instance.position = centre
    instance.material_override = material
    parent.add_child(instance)
    return instance

func _beam(parent: Node3D, a: Vector3, b: Vector3, width: float, material: Material) -> void:
    var instance := _box(parent, Vector3(width, width, a.distance_to(b)), (a + b) * 0.5, material)
    var direction := (b - a).normalized()
    var up := Vector3.UP if absf(direction.dot(Vector3.UP)) < 0.98 else Vector3.RIGHT
    instance.basis = Basis.looking_at(direction, up)

func _cylinder(parent: Node3D, radius: float, height: float, centre: Vector3, material: Material, local_rotation: Vector3, sides: int) -> void:
    var mesh := CylinderMesh.new()
    mesh.top_radius = radius
    mesh.bottom_radius = radius
    mesh.height = height
    mesh.radial_segments = sides
    mesh.rings = 1
    var instance := MeshInstance3D.new()
    instance.mesh = mesh
    instance.position = centre
    instance.rotation = local_rotation
    instance.material_override = material
    parent.add_child(instance)

func _quad(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, outward: Vector3) -> void:
    _triangle(surface, a, b, c, outward)
    _triangle(surface, a, c, d, outward)

func _triangle(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, outward: Vector3) -> void:
    var normal := (b - a).cross(c - a).normalized()
    if normal.dot(outward) < 0.0:
        var temporary := b
        b = c
        c = temporary
        normal = -normal
    # Godot front-face winding is clockwise, opposite the mathematical cross.
    for point in [a, c, b]:
        surface.set_normal(normal)
        surface.set_uv(Vector2.ZERO)
        surface.add_vertex(point)

func _finish(surface: SurfaceTool, parent: Node3D, material: Material, part_name: String) -> void:
    var instance := MeshInstance3D.new()
    instance.name = part_name
    # append_from retains index buffers. Mixing an unindexed authored mesh
    # with indexed BoxMesh/CylinderMesh otherwise leaves the authored vertices
    # outside the final batch's index buffer, making the shell disappear.
    surface.index()
    instance.mesh = surface.commit()
    instance.material_override = material
    parent.add_child(instance)

func _batch_meshes(parent: Node3D) -> void:
    var batches: Dictionary = {}
    for child in parent.get_children():
        var instance := child as MeshInstance3D
        if instance == null or instance.mesh == null or instance.material_override == null:
            continue
        var material_id := instance.material_override.get_instance_id()
        if not batches.has(material_id):
            var surface := SurfaceTool.new()
            surface.begin(Mesh.PRIMITIVE_TRIANGLES)
            batches[material_id] = {"material": instance.material_override, "surface": surface}
        var batch: Dictionary = batches[material_id]
        var builder: SurfaceTool = batch.surface
        for mesh_surface in range(instance.mesh.get_surface_count()):
            builder.append_from(instance.mesh, mesh_surface, instance.transform)
        parent.remove_child(instance)
        instance.queue_free()
    for material_id in batches:
        var batch: Dictionary = batches[material_id]
        _finish(batch.surface, parent, batch.material, "MaterialBatch")
