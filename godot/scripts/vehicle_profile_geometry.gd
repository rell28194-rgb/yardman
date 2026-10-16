extends RefCounted
class_name YardmanVehicleProfileGeometry

# Public fallback geometry for production cars. Dedicated private hero meshes
# supersede this layer when they are available; the legacy recovered sedan is
# never presented as a Crown, Mark X or 992-class car.
const PRODUCTION_IDS := ["toyota_crown", "toyota_mark_x", "port_royal_992"]
const KIT_NAME := "ProfileIdentityGeometry"

static func apply(root: Node3D, profile: Dictionary) -> Dictionary:
    var vehicle_id := str(profile.get("id", "legacy_sedan"))
    var empty := {
        "vehicle_id": vehicle_id,
        "profile_geometry": false,
        "dedicated_mesh": false,
        "hidden_shared_meshes": 0,
        "mesh_parts": 0,
        "signature": "legacy",
    }
    if root == null:
        return empty

    var shell := _resolve_shell(root)
    _restore_shared_geometry(shell)
    _clear_previous_kit(shell)

    if not PRODUCTION_IDS.has(vehicle_id):
        root.set_meta("yardman_geometry_identity", vehicle_id)
        root.set_meta("yardman_geometry_signature", "legacy")
        return empty

    # Catalog-bound hero imports retain their source body and independent rig.
    # Shared Chaser/procedural bodies still receive the profile fallback below.
    if bool(root.get_meta("yardman_dedicated_vehicle_mesh", false)):
        var dedicated := empty.duplicate(true)
        dedicated["dedicated_mesh"] = true
        dedicated["signature"] = "%s:dedicated" % vehicle_id
        root.set_meta("yardman_geometry_identity", vehicle_id)
        root.set_meta("yardman_geometry_signature", dedicated.signature)
        return dedicated

    var hidden := _hide_shared_body(shell)
    var kit := Node3D.new()
    kit.name = KIT_NAME
    shell.add_child(kit)

    var dimensions: Array = profile.get("dimensions_m", [1.85, 1.30, 4.0])
    var width_world := float(dimensions[0]) if dimensions.size() > 0 else 1.85
    var height_world := float(dimensions[1]) if dimensions.size() > 1 else 1.30
    var length_world := float(dimensions[2]) if dimensions.size() > 2 else 4.0
    var sx := maxf(absf(root.scale.x), 0.001)
    var sy := maxf(absf(root.scale.y), 0.001)
    var sz := maxf(absf(root.scale.z), 0.001)
    var width := width_world / sx
    var height := height_world / sy
    var length := length_world / sz
    var radius := float(profile.get("wheel_radius_m", 0.34)) / sy

    var paint := _material("BodyPaintProfile", _profile_color(profile), 0.60, 0.22)
    var trim := _material("ExteriorTrim", Color(0.018, 0.022, 0.028), 0.18, 0.58)
    var glass := _material("WindshieldGlass", Color(0.035, 0.060, 0.078, 0.62), 0.08, 0.08)
    glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    glass.cull_mode = BaseMaterial3D.CULL_DISABLED
    var chrome := _material("ExteriorChrome", Color(0.50, 0.54, 0.58), 0.84, 0.20)
    var headlamp := _lamp_material("HeadlightLens", Color(1.0, 0.92, 0.74), 1.25)
    var taillamp := _lamp_material("StoplightLens", Color(1.0, 0.035, 0.018), 0.42)

    var stats: Dictionary
    match vehicle_id:
        "toyota_crown":
            stats = _build_crown(kit, width, height, length, radius, paint, trim, glass, chrome, headlamp, taillamp)
        "toyota_mark_x":
            stats = _build_mark_x(kit, width, height, length, radius, paint, trim, glass, chrome, headlamp, taillamp)
        "port_royal_992":
            stats = _build_992(kit, width, height, length, radius, paint, trim, glass, chrome, headlamp, taillamp)
        _:
            stats = {"mesh_parts": 0, "signature": "unknown"}

    stats["vehicle_id"] = vehicle_id
    stats["profile_geometry"] = true
    stats["dedicated_mesh"] = false
    stats["hidden_shared_meshes"] = hidden
    kit.set_meta("yardman_vehicle_id", vehicle_id)
    kit.set_meta("yardman_geometry_signature", str(stats.get("signature", vehicle_id)))
    root.set_meta("yardman_geometry_identity", vehicle_id)
    root.set_meta("yardman_geometry_signature", str(stats.get("signature", vehicle_id)))
    root.set_meta("yardman_profile_geometry_stats", stats.duplicate(true))
    return stats

static func _resolve_shell(root: Node3D) -> Node3D:
    var candidate = root.get("shell")
    if candidate is Node3D:
        return candidate as Node3D
    var named := root.find_child("BodyShell", true, false)
    return named as Node3D if named is Node3D else root

static func _restore_shared_geometry(shell: Node3D) -> void:
    for node in shell.find_children("*", "MeshInstance3D", true, false):
        var mesh := node as MeshInstance3D
        if bool(mesh.get_meta("yardman_profile_hidden", false)):
            mesh.visible = true
            mesh.remove_meta("yardman_profile_hidden")

static func _clear_previous_kit(shell: Node3D) -> void:
    var old := shell.get_node_or_null(KIT_NAME)
    if old != null:
        shell.remove_child(old)
        old.free()

static func _hide_shared_body(shell: Node3D) -> int:
    var count := 0
    for node in shell.find_children("*", "MeshInstance3D", true, false):
        var mesh := node as MeshInstance3D
        # Preserve wheel/brake geometry if an imported source nests it under the
        # body node; most current rigs keep wheels as siblings already.
        var label := mesh.name.to_lower()
        if label.contains("wheel") or label.contains("rim") or label.contains("tyre") or label.contains("tire") or label.contains("brake_disc"):
            continue
        mesh.visible = false
        mesh.set_meta("yardman_profile_hidden", true)
        count += 1
    return count

static func _build_crown(parent: Node3D, width: float, height: float, length: float, radius: float,
        paint: Material, trim: Material, glass: Material, chrome: Material, headlamp: Material, taillamp: Material) -> Dictionary:
    var body_h := height * 0.38
    var body_y := radius * 0.56 + body_h * 0.5
    var cabin_h := height * 0.49
    var cabin_len := length * 0.53
    var cabin_y := body_y + body_h * 0.38 + cabin_h * 0.50
    var cabin_z := length * 0.045
    var parts := 0
    parts += _box(parent, "CrownLowerBody", Vector3(width * 0.97, body_h, length * 0.90), Vector3(0, body_y, 0), paint)
    parts += _box(parent, "CrownShoulder", Vector3(width, body_h * 0.34, length * 0.78), Vector3(0, body_y + body_h * 0.39, 0.02 * length), paint)
    parts += _box(parent, "CrownCabin", Vector3(width * 0.77, cabin_h, cabin_len), Vector3(0, cabin_y, cabin_z), paint)
    parts += _box(parent, "CrownRoof", Vector3(width * 0.70, height * 0.065, cabin_len * 0.66), Vector3(0, cabin_y + cabin_h * 0.49, cabin_z + length * 0.02), paint)
    parts += _side_glass(parent, width, cabin_y, cabin_h, cabin_z, cabin_len, glass, 0.78, 0.69)
    parts += _windscreens(parent, width, cabin_y, cabin_h, cabin_z, cabin_len, glass, 0.71, 54.0, 51.0)
    parts += _box(parent, "CrownGrille", Vector3(width * 0.46, height * 0.22, 0.035), Vector3(0, body_y + body_h * 0.02, -length * 0.455), chrome)
    parts += _box(parent, "CrownLowerIntake", Vector3(width * 0.64, height * 0.075, 0.045), Vector3(0, body_y - body_h * 0.23, -length * 0.456), trim)
    parts += _lamp_pair(parent, "CrownHeadlight", width * 0.64, body_y + body_h * 0.24, -length * 0.458, width * 0.22, height * 0.075, headlamp)
    parts += _lamp_pair(parent, "CrownTaillight", width * 0.66, body_y + body_h * 0.23, length * 0.458, width * 0.24, height * 0.075, taillamp)
    return {"mesh_parts": parts, "signature": "crown:luxury-upright:%.2f:%.2f:%.2f" % [width, height, length], "cabin_height": cabin_h, "cabin_center_z": cabin_z}

static func _build_mark_x(parent: Node3D, width: float, height: float, length: float, radius: float,
        paint: Material, trim: Material, glass: Material, chrome: Material, headlamp: Material, taillamp: Material) -> Dictionary:
    var body_h := height * 0.35
    var body_y := radius * 0.54 + body_h * 0.5
    var cabin_h := height * 0.41
    var cabin_len := length * 0.49
    var cabin_y := body_y + body_h * 0.38 + cabin_h * 0.49
    var cabin_z := length * 0.055
    var parts := 0
    parts += _box(parent, "MarkXLowerBody", Vector3(width * 0.98, body_h, length * 0.91), Vector3(0, body_y, 0), paint)
    parts += _box(parent, "MarkXShoulder", Vector3(width, body_h * 0.30, length * 0.76), Vector3(0, body_y + body_h * 0.40, length * 0.01), paint)
    parts += _box(parent, "MarkXCabin", Vector3(width * 0.75, cabin_h, cabin_len), Vector3(0, cabin_y, cabin_z), paint)
    parts += _box(parent, "MarkXRoof", Vector3(width * 0.67, height * 0.052, cabin_len * 0.60), Vector3(0, cabin_y + cabin_h * 0.49, cabin_z + length * 0.02), paint)
    parts += _side_glass(parent, width, cabin_y, cabin_h, cabin_z, cabin_len, glass, 0.77, 0.62)
    parts += _windscreens(parent, width, cabin_y, cabin_h, cabin_z, cabin_len, glass, 0.68, 58.0, 47.0)
    parts += _box(parent, "MarkXSportGrille", Vector3(width * 0.58, height * 0.13, 0.040), Vector3(0, body_y - body_h * 0.02, -length * 0.461), trim)
    parts += _box(parent, "MarkXGrilleBar", Vector3(width * 0.48, height * 0.025, 0.046), Vector3(0, body_y + body_h * 0.12, -length * 0.463), chrome)
    parts += _lamp_pair(parent, "MarkXHeadlight", width * 0.67, body_y + body_h * 0.24, -length * 0.462, width * 0.24, height * 0.062, headlamp)
    parts += _lamp_pair(parent, "MarkXTaillight", width * 0.69, body_y + body_h * 0.21, length * 0.462, width * 0.25, height * 0.064, taillamp)
    return {"mesh_parts": parts, "signature": "markx:sport-sedan:%.2f:%.2f:%.2f" % [width, height, length], "cabin_height": cabin_h, "cabin_center_z": cabin_z}

static func _build_992(parent: Node3D, width: float, height: float, length: float, radius: float,
        paint: Material, trim: Material, glass: Material, chrome: Material, headlamp: Material, taillamp: Material) -> Dictionary:
    var body_h := height * 0.31
    var body_y := radius * 0.46 + body_h * 0.50
    var cabin_h := height * 0.36
    var cabin_len := length * 0.40
    var cabin_y := body_y + body_h * 0.34 + cabin_h * 0.47
    var cabin_z := length * 0.075
    var parts := 0
    parts += _box(parent, "PortRoyalLowerBody", Vector3(width, body_h, length * 0.88), Vector3(0, body_y, length * 0.01), paint)
    parts += _box(parent, "PortRoyalRearHaunch", Vector3(width * 1.015, body_h * 0.47, length * 0.33), Vector3(0, body_y + body_h * 0.28, length * 0.245), paint)
    parts += _box(parent, "PortRoyalNose", Vector3(width * 0.90, body_h * 0.42, length * 0.29), Vector3(0, body_y + body_h * 0.25, -length * 0.30), paint)
    parts += _box(parent, "PortRoyalCabin", Vector3(width * 0.70, cabin_h, cabin_len), Vector3(0, cabin_y, cabin_z), paint)
    parts += _box(parent, "PortRoyalRoof", Vector3(width * 0.61, height * 0.045, cabin_len * 0.54), Vector3(0, cabin_y + cabin_h * 0.48, cabin_z + length * 0.02), paint)
    parts += _side_glass(parent, width, cabin_y, cabin_h, cabin_z, cabin_len, glass, 0.72, 0.58)
    parts += _windscreens(parent, width, cabin_y, cabin_h, cabin_z, cabin_len, glass, 0.62, 62.0, 43.0)
    parts += _box(parent, "PortRoyalFrontIntake", Vector3(width * 0.72, height * 0.075, 0.040), Vector3(0, body_y - body_h * 0.16, -length * 0.442), trim)
    parts += _box(parent, "PortRoyalRearDeck", Vector3(width * 0.77, height * 0.045, length * 0.18), Vector3(0, body_y + body_h * 0.63, length * 0.34), paint)
    parts += _lamp_pair(parent, "PortRoyalHeadlight", width * 0.61, body_y + body_h * 0.31, -length * 0.432, width * 0.18, height * 0.095, headlamp)
    parts += _box(parent, "PortRoyalRearLightBar", Vector3(width * 0.76, height * 0.045, 0.035), Vector3(0, body_y + body_h * 0.28, length * 0.442), taillamp)
    return {"mesh_parts": parts, "signature": "portroyal992:rear-engine-coupe:%.2f:%.2f:%.2f" % [width, height, length], "cabin_height": cabin_h, "cabin_center_z": cabin_z}

static func _side_glass(parent: Node3D, width: float, cabin_y: float, cabin_h: float, cabin_z: float,
        cabin_len: float, material: Material, width_factor: float, length_factor: float) -> int:
    var count := 0
    var x := width * width_factor * 0.5
    for sign_value in [-1.0, 1.0]:
        count += _box(parent, "SideWindowGlass", Vector3(width * 0.018, cabin_h * 0.52, cabin_len * length_factor), Vector3(sign_value * x, cabin_y + cabin_h * 0.05, cabin_z), material)
    return count

static func _windscreens(parent: Node3D, width: float, cabin_y: float, cabin_h: float, cabin_z: float,
        cabin_len: float, material: Material, width_factor: float, front_angle: float, rear_angle: float) -> int:
    var pane_size := Vector3(width * width_factor, cabin_h * 0.58, maxf(cabin_h * 0.035, 0.018))
    var front := _new_box("FrontWindshieldGlass", pane_size, material)
    front.position = Vector3(0, cabin_y + cabin_h * 0.02, cabin_z - cabin_len * 0.48)
    front.rotation.x = deg_to_rad(front_angle)
    parent.add_child(front)
    var rear := _new_box("RearWindshieldGlass", pane_size, material)
    rear.position = Vector3(0, cabin_y + cabin_h * 0.02, cabin_z + cabin_len * 0.48)
    rear.rotation.x = deg_to_rad(-rear_angle)
    parent.add_child(rear)
    return 2

static func _lamp_pair(parent: Node3D, prefix: String, spacing: float, y: float, z: float,
        lamp_width: float, lamp_height: float, material: Material) -> int:
    for sign_value in [-1.0, 1.0]:
        _box(parent, prefix, Vector3(lamp_width, lamp_height, 0.032), Vector3(sign_value * spacing * 0.5, y, z), material)
    return 2

static func _box(parent: Node3D, name: String, size: Vector3, position: Vector3, material: Material) -> int:
    var node := _new_box(name, size, material)
    node.position = position
    parent.add_child(node)
    return 1

static func _new_box(name: String, size: Vector3, material: Material) -> MeshInstance3D:
    var mesh := BoxMesh.new()
    mesh.size = Vector3(maxf(size.x, 0.01), maxf(size.y, 0.01), maxf(size.z, 0.01))
    mesh.material = material
    var node := MeshInstance3D.new()
    node.name = name
    node.mesh = mesh
    return node

static func _material(name: String, color: Color, metallic: float, roughness: float) -> StandardMaterial3D:
    var material := StandardMaterial3D.new()
    material.resource_name = name
    material.albedo_color = color
    material.metallic = metallic
    material.roughness = roughness
    return material

static func _lamp_material(name: String, color: Color, energy: float) -> StandardMaterial3D:
    var material := _material(name, color, 0.05, 0.18)
    material.emission_enabled = true
    material.emission = color
    material.emission_energy_multiplier = energy
    return material

static func _profile_color(profile: Dictionary) -> Color:
    var value = profile.get("paint_rgb", [0.14, 0.31, 0.37])
    if value is Array and value.size() >= 3:
        return Color(clampf(float(value[0]), 0.0, 1.0), clampf(float(value[1]), 0.0, 1.0), clampf(float(value[2]), 0.0, 1.0))
    return Color(0.14, 0.31, 0.37)
