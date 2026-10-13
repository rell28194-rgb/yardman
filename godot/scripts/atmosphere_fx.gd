extends Node
class_name YardmanAtmosphereFX

const CLOUD_SIZE_M := 2600.0
const SKY_DISTANCE_M := 3200.0

var _camera: Camera3D
var _sun_light: DirectionalLight3D
var _clouds: Array[MeshInstance3D] = []
var _sun_disc: MeshInstance3D
var _moon_disc: MeshInstance3D
var _root: Node3D
var _cloud_texture: ImageTexture
var _disc_texture: ImageTexture
var _clock := 0.0

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    call_deferred("_attach")

func _attach() -> void:
    var scene := get_tree().current_scene
    if scene == null:
        await get_tree().process_frame
        scene = get_tree().current_scene
    if scene == null:
        return
    _root = Node3D.new()
    _root.name = "AtmosphereFX"
    scene.add_child(_root)
    _cloud_texture = _make_cloud_texture()
    _disc_texture = _make_disc_texture()
    _make_cloud_layer(0.0, 0.23, 1.0)
    _make_cloud_layer(170.0, 0.14, 0.72)
    _sun_disc = _make_disc("SunDisc", Color(1.0, 0.93, 0.70), 38.0, 2.3)
    _moon_disc = _make_disc("MoonDisc", Color(0.78, 0.84, 0.94), 34.0, 1.25)
    _resolve_scene_nodes()

func _resolve_scene_nodes() -> void:
    var scene := get_tree().current_scene
    if scene == null:
        return
    _camera = scene.get_viewport().get_camera_3d()
    for child in scene.get_children():
        if child is DirectionalLight3D:
            _sun_light = child as DirectionalLight3D
            break

func _process(delta: float) -> void:
    if _root == null or not is_instance_valid(_root):
        return
    if _camera == null or not is_instance_valid(_camera):
        _resolve_scene_nodes()
        return
    _clock = fmod(_clock + delta, 100000.0)
    var scene := get_tree().current_scene
    var hour := 10.0
    if scene != null:
        var value = scene.get("day_hour")
        if value is float or value is int:
            hour = float(value)
    _update_celestial(hour)
    _update_clouds(delta)

func _make_cloud_layer(y_offset: float, alpha: float, scale_value: float) -> void:
    var plane := PlaneMesh.new()
    plane.size = Vector2(CLOUD_SIZE_M * scale_value, CLOUD_SIZE_M * scale_value)
    plane.subdivide_width = 1
    plane.subdivide_depth = 1
    var material := StandardMaterial3D.new()
    material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    material.cull_mode = BaseMaterial3D.CULL_DISABLED
    material.albedo_texture = _cloud_texture
    material.albedo_color = Color(1.0, 1.0, 1.0, alpha)
    material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
    var cloud := MeshInstance3D.new()
    cloud.name = "CloudLayer%d" % _clouds.size()
    cloud.mesh = plane
    cloud.material_override = material
    cloud.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    cloud.set_meta("height_offset", y_offset)
    cloud.set_meta("drift_rate", 0.0025 + float(_clouds.size()) * 0.0017)
    _root.add_child(cloud)
    _clouds.append(cloud)

func _make_disc(node_name: String, color: Color, diameter_m: float, energy: float) -> MeshInstance3D:
    var quad := QuadMesh.new()
    quad.size = Vector2(diameter_m, diameter_m)
    var material := StandardMaterial3D.new()
    material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
    material.cull_mode = BaseMaterial3D.CULL_DISABLED
    material.albedo_texture = _disc_texture
    material.albedo_color = color
    material.emission_enabled = true
    material.emission = color
    material.emission_energy_multiplier = energy
    var disc := MeshInstance3D.new()
    disc.name = node_name
    disc.mesh = quad
    disc.material_override = material
    disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    _root.add_child(disc)
    return disc

func _update_celestial(hour: float) -> void:
    var phase := (hour - 6.0) * PI / 12.0
    var azimuth := deg_to_rad(-55.0 + hour * 6.0)
    var horizontal := cos(phase)
    var sun_direction := Vector3(sin(azimuth) * horizontal, sin(phase), cos(azimuth) * horizontal).normalized()
    var moon_direction := -sun_direction
    var origin := _camera.global_position
    _sun_disc.global_position = origin + sun_direction * SKY_DISTANCE_M
    _moon_disc.global_position = origin + moon_direction * SKY_DISTANCE_M
    _sun_disc.visible = sun_direction.y > -0.035
    _moon_disc.visible = moon_direction.y > -0.035
    if _sun_light != null and is_instance_valid(_sun_light):
        var daylight := clampf(sun_direction.y * 1.25, 0.0, 1.0)
        _sun_light.light_energy = maxf(_sun_light.light_energy, daylight * 1.15)

func _update_clouds(delta: float) -> void:
    var base_y := maxf(650.0, _camera.global_position.y + 240.0)
    for index in range(_clouds.size()):
        var cloud := _clouds[index]
        var height_offset := float(cloud.get_meta("height_offset", 0.0))
        var rate := float(cloud.get_meta("drift_rate", 0.003))
        cloud.global_position = Vector3(_camera.global_position.x, base_y + height_offset, _camera.global_position.z)
        cloud.rotation.y = fmod(cloud.rotation.y + delta * rate, TAU)

func _make_cloud_texture() -> ImageTexture:
    var size := 256
    var noise := FastNoiseLite.new()
    noise.seed = 128194
    noise.frequency = 0.022
    noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
    noise.fractal_type = FastNoiseLite.FRACTAL_FBM
    noise.fractal_octaves = 5
    noise.fractal_gain = 0.56
    var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
    for y in range(size):
        for x in range(size):
            var n := noise.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
            var density := smoothstep(0.47, 0.72, n)
            image.set_pixel(x, y, Color(1.0, 1.0, 1.0, density))
    image.generate_mipmaps()
    return ImageTexture.create_from_image(image)

func _make_disc_texture() -> ImageTexture:
    var size := 64
    var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
    var center := Vector2(size * 0.5 - 0.5, size * 0.5 - 0.5)
    var radius := size * 0.47
    for y in range(size):
        for x in range(size):
            var distance := Vector2(float(x), float(y)).distance_to(center) / radius
            var alpha := 1.0 - smoothstep(0.88, 1.0, distance)
            image.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))
    image.generate_mipmaps()
    return ImageTexture.create_from_image(image)
