extends RefCounted
class_name YardmanWorldVisuals

const TERRAIN_SHADER = preload("res://shaders/terrain_surface.gdshader")
const LEAF_SHADER = preload("res://shaders/foliage.gdshader")
const BARK_SHADER = preload("res://shaders/tree_bark.gdshader")
const References = preload("res://scripts/reference_assets.gd")
const CULL_CELL_M := 256.0
const ROAD_BUCKET_M := 64.0
const MAX_PLANTS := 1800
const PROFILES := {
    "Performance": {"trees": 180, "road_radius": 1, "terrain_radius": 1, "shadows": false},
    "Balanced": {"trees": 420, "road_radius": 2, "terrain_radius": 1, "shadows": true},
    "Quality": {"trees": 800, "road_radius": 2, "terrain_radius": 2, "shadows": true},
    "Ultra": {"trees": 1400, "road_radius": 3, "terrain_radius": 2, "shadows": true},
    "Custom": {"trees": 500, "road_radius": 2, "terrain_radius": 1, "shadows": true},
}
var quality := "Balanced"
var custom: Dictionary = {}
var _tree_mesh: ArrayMesh
var _plant_meshes: Dictionary = {}
var _reference_meshes: Dictionary = {}
var _surface_noise: ImageTexture
var _sky_material: ProceduralSkyMaterial
var _sun: DirectionalLight3D

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

func terrain_material(tile_origin: Vector2, overview: bool = false) -> ShaderMaterial:
    var material := ShaderMaterial.new()
    material.shader = TERRAIN_SHADER
    if _surface_noise == null:
        _surface_noise = _make_surface_noise()
    material.set_shader_parameter("surface_noise", _surface_noise)
    # Noise repeats on a 16 km canonical grid, so small GPU floats suffice.
    material.set_shader_parameter("tile_origin", tile_origin)
    material.set_shader_parameter("overview", overview)
    var grass := References.texture("ground_grass.png")
    var dry_grass := References.texture("ground_dry_grass.png")
    if grass != null and dry_grass != null:
        material.set_shader_parameter("reference_grass", grass)
        material.set_shader_parameter("reference_dry_grass", dry_grass)
        material.set_shader_parameter("has_reference_ground", true)
    # Direct Beta2 source normal is intentionally independent of the albedo pair:
    # if an older/private pack lacks it the shader keeps its procedural micro-normal.
    var grass_normal := References.texture("beta2_ucaptain_scrub_grass_normal.ktx")
    if grass_normal != null:
        material.set_shader_parameter("reference_grass_normal", grass_normal)
        material.set_shader_parameter("has_reference_grass_normal", true)
    var rock := References.texture("ground_rock.png")
    if rock != null:
        material.set_shader_parameter("reference_rock", rock)
        material.set_shader_parameter("has_reference_rock", true)
    return material

func _make_surface_noise() -> ImageTexture:
    var noises: Array[FastNoiseLite] = []
    for i in range(3):
        var noise := FastNoiseLite.new()
        noise.seed = 28194 + i * 3719
        noise.frequency = 0.065 + float(i) * 0.027
        noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
        noise.fractal_octaves = 4
        noise.fractal_type = FastNoiseLite.FRACTAL_FBM
        noises.append(noise)
    var image := Image.create(256, 256, false, Image.FORMAT_RGB8)
    for y in range(256):
        for x in range(256):
            # Crossfade rolled noise samples at each edge. This prevents a
            # dark seam on repeated land without importing a bitmap asset.
            var values := Vector3.ZERO
            for channel in range(3):
                var nx := float(x)
                var ny := float(y)
                var wx := smoothstep(224.0, 255.0, nx)
                var wy := smoothstep(224.0, 255.0, ny)
                var first := lerpf(noises[channel].get_noise_2d(nx, ny), noises[channel].get_noise_2d(nx - 256.0, ny), wx)
                var second := lerpf(noises[channel].get_noise_2d(nx, ny - 256.0), noises[channel].get_noise_2d(nx - 256.0, ny - 256.0), wx)
                values[channel] = clampf(lerpf(first, second, wy) * 0.73 + 0.5, 0.0, 1.0)
            image.set_pixel(x, y, Color(values.x, values.y, values.z))
    image.generate_mipmaps()
    return ImageTexture.create_from_image(image)

func _regional_dryness(position_world: Vector2) -> float:
    # A visual proxy, not surveyed land cover: the western/southern envelope
    # is generally warmer and drier than the eastern mountain/north coast.
    # The compiled national coordinate frame is anchored at Kingston:
    # west is negative X and the northern coast is negative Z.
    var south := smoothstep(-18000.0, 18000.0, position_world.y)
    var west := 1.0 - smoothstep(-90000.0, 15000.0, position_world.x)
    return clampf(0.12 + south * 0.30 + west * south * 0.18, 0.1, 0.6)

func configure_environment(environment: Environment, sun: DirectionalLight3D) -> void:
    _sun = sun
    _sky_material = ProceduralSkyMaterial.new()
    _sky_material.sky_top_color = Color(0.16, 0.39, 0.67)
    _sky_material.sky_horizon_color = Color(0.76, 0.86, 0.91)
    _sky_material.ground_horizon_color = Color(0.73, 0.79, 0.76)
    _sky_material.ground_bottom_color = Color(0.22, 0.28, 0.21)
    _sky_material.sky_curve = 0.13
    _sky_material.sun_angle_max = 7.0
    _sky_material.sun_curve = 0.04
    var sky := Sky.new()
    sky.sky_material = _sky_material
    environment.sky = sky
    environment.background_mode = Environment.BG_SKY
    environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
    environment.ambient_light_color = Color(0.86, 0.89, 0.93)
    environment.ambient_light_energy = 0.72
    environment.ambient_light_sky_contribution = 0.22
    environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
    environment.tonemap_exposure = 1.05
    environment.fog_enabled = true
    environment.fog_density = 0.000020
    environment.fog_light_color = Color(0.78, 0.85, 0.86)
    environment.fog_light_energy = 0.7
    environment.fog_sky_affect = 0.14
    sun.light_color = Color(1.0, 0.96, 0.85)
    sun.light_energy = 1.2
    sun.directional_shadow_max_distance = 100.0
    sun.shadow_bias = 0.04
    sun.shadow_normal_bias = 1.2
    update_daylight(10.0, environment)

func update_daylight(hour: float, environment: Environment) -> void:
    var daylight := clampf(sin((hour - 6.0) * PI / 12.0), 0.0, 1.0)
    var golden := clampf(1.0 - daylight * 2.4, 0.0, 1.0)
    var moonlight := 1.0 - smoothstep(0.02, 0.14, daylight)
    if _sun != null:
        _sun.rotation_degrees = Vector3(-12.0 - daylight * 62.0, hour * 15.0 - 180.0, 0.0)
        _sun.light_energy = lerpf(0.025, 1.2, daylight)
        _sun.light_color = Color(0.42, 0.49, 0.67).lerp(Color(1.0, 0.96, 0.85), daylight).lerp(Color(1.0, 0.68, 0.42), golden * daylight)
    if _sky_material != null:
        var night_top := Color(0.008, 0.014, 0.035)
        var night_horizon := Color(0.035, 0.055, 0.09)
        _sky_material.sky_top_color = night_top.lerp(Color(0.16, 0.39, 0.67), daylight)
        _sky_material.sky_horizon_color = night_horizon.lerp(Color(0.76, 0.86, 0.91), daylight)
    environment.ambient_light_color = Color(0.11, 0.15, 0.24).lerp(Color(0.86, 0.89, 0.93), daylight)
    environment.ambient_light_energy = lerpf(0.16, 0.72, daylight) + moonlight * 0.05
