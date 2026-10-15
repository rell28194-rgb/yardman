extends RefCounted
class_name YardmanVehicleVisualStyler

# Shared hero-material pass for recovered and procedural vehicle geometry.
# It never claims a shared mesh is a dedicated vehicle model: the profile only
# changes material presentation while dedicated meshes remain an asset gate.
const STYLE_PRESETS := {
    "legacy_sedan": {"metallic": 0.52, "roughness": 0.27, "clearcoat_roughness": 0.18, "glass": [0.055, 0.125, 0.16], "wheel": [0.54, 0.58, 0.62]},
    # Recovered Car Parking Crown material C_CG_color_unity is dielectric
    # (_Metallic=0) with high paint smoothness (_Parameters.x=0.878). Keep the
    # Yardman clearcoat pass, but do not turn the body into metallic-flake paint.
    "toyota_crown": {"metallic": 0.0, "roughness": 0.12, "clearcoat_roughness": 0.10, "glass": [0.035, 0.060, 0.080], "wheel": [0.24, 0.27, 0.30]},
    "toyota_mark_x": {"metallic": 0.64, "roughness": 0.18, "clearcoat_roughness": 0.10, "glass": [0.045, 0.070, 0.085], "wheel": [0.62, 0.65, 0.68]},
    "port_royal_992": {"metallic": 0.68, "roughness": 0.16, "clearcoat_roughness": 0.085, "glass": [0.025, 0.045, 0.055], "wheel": [0.11, 0.12, 0.13]},
}

static func apply(root: Node3D, profile: Dictionary) -> Dictionary:
    if root == null:
        return {"paint_materials": 0, "glass_materials": 0, "wheel_materials": 0, "vehicle_id": ""}
    var vehicle_id := str(profile.get("id", "legacy_sedan"))
    var preset: Dictionary = STYLE_PRESETS.get(vehicle_id, STYLE_PRESETS.legacy_sedan)
    var paint := _profile_color(profile, "paint_rgb", Color(0.14, 0.31, 0.37))
    var glass := _array_color(preset.get("glass", [0.055, 0.125, 0.16]), Color(0.055, 0.125, 0.16))
    var wheel := _array_color(preset.get("wheel", [0.54, 0.58, 0.62]), Color(0.54, 0.58, 0.62))
    var clones: Dictionary = {}
    var stats := {"paint_materials": 0, "glass_materials": 0, "wheel_materials": 0, "vehicle_id": vehicle_id, "paint_rgb": [paint.r, paint.g, paint.b]}
    var meshes: Array[MeshInstance3D] = []
    if root is MeshInstance3D:
        meshes.append(root as MeshInstance3D)
    for node in root.find_children("*", "MeshInstance3D", true, false):
        meshes.append(node as MeshInstance3D)
    for instance in meshes:
        _style_instance(instance, paint, glass, wheel, preset, clones, stats)
    root.set_meta("yardman_vehicle_visual_id", vehicle_id)
    root.set_meta("yardman_vehicle_visual_stats", stats.duplicate(true))
    return stats

static func _style_instance(instance: MeshInstance3D, paint: Color, glass: Color, wheel: Color,
        preset: Dictionary, clones: Dictionary, stats: Dictionary) -> void:
    if instance.material_override is StandardMaterial3D:
        var override_source := instance.material_override as StandardMaterial3D
        var override_kind := _classify(instance.name, override_source)
        if not override_kind.is_empty():
            instance.material_override = _styled_clone(override_source, override_kind, paint, glass, wheel, preset, clones)
            _increment(stats, override_kind)
            return
    if instance.mesh == null:
        return
    for surface in range(instance.mesh.get_surface_count()):
        var source := instance.get_active_material(surface) as StandardMaterial3D
        if source == null:
            continue
        var kind := _classify(instance.name, source)
        if kind.is_empty():
            continue
        instance.set_surface_override_material(surface, _styled_clone(source, kind, paint, glass, wheel, preset, clones))
        _increment(stats, kind)

static func _styled_clone(source: StandardMaterial3D, kind: String, paint: Color, glass: Color, wheel: Color,
        preset: Dictionary, clones: Dictionary) -> StandardMaterial3D:
    var cache_key := "%d:%s" % [source.get_instance_id(), kind]
    if clones.has(cache_key):
        return clones[cache_key] as StandardMaterial3D
    var material := source.duplicate() as StandardMaterial3D
    material.resource_local_to_scene = true
    material.resource_name = source.resource_name
    match kind:
        "paint":
            material.albedo_color = Color(paint.r, paint.g, paint.b, source.albedo_color.a)
            material.metallic = float(preset.get("metallic", 0.60))
            material.roughness = float(preset.get("roughness", 0.20))
            material.clearcoat_enabled = true
            material.clearcoat_roughness = float(preset.get("clearcoat_roughness", 0.12))
        "glass":
            material.albedo_color = Color(glass.r, glass.g, glass.b, 0.56)
            material.metallic = 0.08
            material.roughness = 0.075
            material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
            material.cull_mode = BaseMaterial3D.CULL_DISABLED
        "wheel":
            material.albedo_color = Color(wheel.r, wheel.g, wheel.b, source.albedo_color.a)
            material.metallic = maxf(source.metallic, 0.74)
            material.roughness = clampf(source.roughness, 0.20, 0.34)
    clones[cache_key] = material
    return material

static func _classify(node_name: String, material: StandardMaterial3D) -> String:
    var label := (node_name + " " + material.resource_name).to_lower()
    if _contains_any(label, ["stoplight", "brake", "reverse", "headlight", "lamp", "indicator", "emissive", "plate"]):
        return ""
    if _contains_any(label, ["glass", "window", "windshield", "windscreen"]):
        return "glass"
    if _contains_any(label, ["rim", "alloy", "chrome", "wheelmetal", "wheel_metal"]):
        return "wheel"
    if _contains_any(label, ["paint", "body", "bodyshell", "exterior", "hood", "bonnet", "door", "fender", "quarterpanel"]):
        return "paint"
    if _contains_any(label, ["tyre", "tire", "rubber", "road"]):
        return ""
    var color := material.albedo_color
    var luminance := color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722
    # Procedural fallback batches have generic names, so material properties are
    # the only stable classification signal. Ranges intentionally avoid lamps,
    # tyres and highly metallic chrome.
    if material.metallic >= 0.35 and material.metallic <= 0.70 and material.roughness >= 0.17 and material.roughness <= 0.38 and luminance >= 0.10 and luminance <= 0.46:
        return "paint"
    if material.roughness < 0.18 and material.metallic >= 0.20 and material.metallic <= 0.58 and luminance < 0.24:
        return "glass"
    if material.metallic >= 0.72 and material.roughness <= 0.42 and luminance > 0.24:
        return "wheel"
    return ""

static func _contains_any(label: String, tokens: Array) -> bool:
    for token in tokens:
        if label.contains(str(token)):
            return true
    return false

static func _profile_color(profile: Dictionary, key: String, fallback: Color) -> Color:
    return _array_color(profile.get(key, []), fallback)

static func _array_color(value: Variant, fallback: Color) -> Color:
    if value is Array and value.size() >= 3:
        return Color(clampf(float(value[0]), 0.0, 1.0), clampf(float(value[1]), 0.0, 1.0), clampf(float(value[2]), 0.0, 1.0), 1.0)
    return fallback

static func _increment(stats: Dictionary, kind: String) -> void:
    var key := "%s_materials" % kind
    stats[key] = int(stats.get(key, 0)) + 1
