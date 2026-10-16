extends Node
class_name YardmanAtmosphereFX

const CLOUD_SIZE_M := 2600.0
const SKY_DISTANCE_M := 3200.0
const WEATHER_LEVELS := {
    "clear": 0.0,
    "showers": 0.36,
    "rain": 0.72,
    "storm": 1.0,
}

signal weather_changed(mode: String)

var weather_mode := "clear"
var rain_intensity := 0.0
var wetness := 0.0
var standing_water := 0.0

var _camera: Camera3D
var _sun_light: DirectionalLight3D
var _environment: Environment
var _clouds: Array[MeshInstance3D] = []
var _sun_disc: MeshInstance3D
var _moon_disc: MeshInstance3D
var _root: Node3D
var _cloud_texture: ImageTexture
var _disc_texture: ImageTexture
var _rain: GPUParticles3D
var _rain_process: ParticleProcessMaterial
var _rain_target := 0.0
var _particle_budget := 900
var _clock := 0.0
var _surface_clock := 0.0
var _visual_clock := 999.0
const VISUAL_UPDATE_INTERVAL := 0.05

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    add_to_group("yardman_render_quality")
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
    _make_rain()
    _resolve_scene_nodes()

func _resolve_scene_nodes() -> void:
    var scene := get_tree().current_scene
    if scene == null:
        return
    _camera = scene.get_viewport().get_camera_3d()
    var env_value = scene.get("environment")
    if env_value is Environment:
        _environment = env_value as Environment
    if _sun_light == null or not is_instance_valid(_sun_light):
        for child in scene.get_children():
            if child is DirectionalLight3D:
                _sun_light = child as DirectionalLight3D
                break

func _process(delta: float) -> void:
    _update_weather_state(delta)
    var scene := get_tree().current_scene
    _surface_clock += delta
    if _surface_clock >= 0.10:
        _surface_clock = 0.0
        _apply_surface_weather(scene)
    if _root == null or not is_instance_valid(_root):
        return
    if _camera == null or not is_instance_valid(_camera):
        _resolve_scene_nodes()
        return
    _visual_clock += delta
    if _visual_clock < VISUAL_UPDATE_INTERVAL:
        return
    var visual_step := _visual_clock
    _visual_clock = 0.0
    _clock = fmod(_clock + visual_step, 100000.0)
    var hour := 10.0
    if scene != null:
        var value = scene.get("day_hour")
        if value is float or value is int:
            hour = float(value)
    _update_celestial(hour)
    _update_clouds(visual_step)
    _update_weather_visuals()

func set_weather(mode: String, immediate: bool = false) -> bool:
    var normalized := mode.to_lower()
    if not WEATHER_LEVELS.has(normalized):
        push_warning("Unknown Yardman weather mode: %s" % mode)
        return false
    weather_mode = normalized
    _rain_target = float(WEATHER_LEVELS[normalized])
    if immediate:
        rain_intensity = _rain_target
        wetness = _rain_target
        standing_water = _standing_water_target(rain_intensity, wetness)
    weather_changed.emit(weather_mode)
    return true

func weather_snapshot() -> Dictionary:
    return {
        "mode": weather_mode,
        "target_rain": _rain_target,
        "rain_intensity": rain_intensity,
        "wetness": wetness,
        "standing_water": standing_water,
        "particle_budget": _particle_budget,
    }

func apply_render_policy(active: Dictionary) -> void:
    var quality := str(active.get("quality", "Balanced"))
    var renderer := str(active.get("renderer", "gles"))
    var safe := str(active.get("road_variant", "safe")) == "safe"
    match quality:
        "Ultra":
            _particle_budget = 1700
        "Quality":
            _particle_budget = 1300
        "Balanced":
            _particle_budget = 900
        _:
            _particle_budget = 520
    if renderer == "gles" or safe:
        _particle_budget = mini(_particle_budget, 620)
    if _rain != null:
        _rain.amount = _particle_budget

func _update_weather_state(delta: float) -> void:
    rain_intensity = move_toward(rain_intensity, _rain_target, delta * 0.22)
    var wet_target := clampf(rain_intensity * 1.08, 0.0, 1.0)
    var wet_rate := 0.18 if wet_target > wetness else 0.010
    wetness = move_toward(wetness, wet_target, delta * wet_rate)
    var pool_target := _standing_water_target(rain_intensity, wetness)
    var pool_rate := 0.12 if pool_target > standing_water else 0.004
    standing_water = move_toward(standing_water, pool_target, delta * pool_rate)

static func _standing_water_target(rain_value: float, wet_value: float) -> float:
    var rain_factor := clampf((rain_value - 0.25) / 0.75, 0.0, 1.0)
    var wet_factor := clampf((wet_value - 0.30) / 0.70, 0.0, 1.0)
    return rain_factor * wet_factor

func _make_rain() -> void:
    _rain = GPUParticles3D.new()
    _rain.name = "RainField"
    _rain.amount = _particle_budget
    _rain.lifetime = 1.25
    _rain.visibility_aabb = AABB(Vector3(-28.0, -30.0, -28.0), Vector3(56.0, 58.0, 56.0))
    _rain.emitting = false

    _rain_process = ParticleProcessMaterial.new()
    _rain_process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
    _rain_process.emission_box_extents = Vector3(22.0, 1.0, 22.0)
    _rain_process.direction = Vector3(0.10, -1.0, 0.04)
    _rain_process.spread = 3.0
    _rain_process.gravity = Vector3(0.0, -16.0, 0.0)
    _rain_process.initial_velocity_min = 24.0
    _rain_process.initial_velocity_max = 34.0
    _rain_process.color = Color(0.72, 0.82, 0.92, 0.58)
    _rain.process_material = _rain_process

    var drop := QuadMesh.new()
    drop.size = Vector2(0.025, 0.72)
    var drop_material := StandardMaterial3D.new()
    drop_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    drop_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    drop_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
    drop_material.albedo_color = Color(0.74, 0.84, 0.95, 0.50)
    drop.material = drop_material
    _rain.draw_pass_1 = drop
    _root.add_child(_rain)

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
    cloud.set_meta("base_alpha", alpha)
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

func _update_weather_visuals() -> void:
    if _rain != null:
        _rain.global_position = _camera.global_position + Vector3(0.0, 22.0, 0.0)
        _rain.emitting = rain_intensity > 0.025
        _rain.amount_ratio = clampf(rain_intensity, 0.08, 1.0) if _rain.emitting else 0.0
    for cloud in _clouds:
        var material := cloud.material_override as StandardMaterial3D
        if material == null:
            continue
        var base_alpha := float(cloud.get_meta("base_alpha", 0.20))
        var storm_tint := Color(0.48, 0.54, 0.60, base_alpha + rain_intensity * 0.20)
        material.albedo_color = Color(1.0, 1.0, 1.0, base_alpha).lerp(storm_tint, rain_intensity)
    if _environment != null:
        _environment.fog_density = lerpf(0.000020, 0.000110, rain_intensity)
        _environment.fog_sky_affect = lerpf(0.14, 0.42, rain_intensity)
        _environment.tonemap_exposure = lerpf(1.05, 0.90, rain_intensity)

func _apply_surface_weather(scene: Node) -> void:
    if scene == null:
        return
    var roads_value = scene.get("roads")
    if not roads_value is Object:
        return
    for property_name in ["_asphalt_material", "_dirt_material"]:
        var value = roads_value.get(property_name)
        if value is ShaderMaterial:
            var material := value as ShaderMaterial
            material.set_shader_parameter("wetness", wetness)
            material.set_shader_parameter("standing_water", standing_water)

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
