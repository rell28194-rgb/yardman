extends Node

# Map-first presentation bootstrap. This branch is deliberately about the
# Jamaica world itself; it does not add AI, jobs, traffic or placeholder
# vehicle systems. It also carries forward the proven graphics-pass image
# treatment without reviving that older branch's runtime stack.
var _applied := false
var _buildings: JamaicaBuildingStreamer
var _scene: Node
var _sky_material: ProceduralSkyMaterial
var _cloud_texture: ImageTexture
var _cloud_clock := 0.0

func _ready() -> void:
    set_process(true)

func _process(delta: float) -> void:
    if _applied:
        _cloud_clock += delta
        if _cloud_clock >= 0.5:
            _cloud_clock = 0.0
            _update_cloud_tint()
        return
    var scene := get_tree().current_scene
    if scene == null or not scene.has_method("set_quality"):
        return

    # Keep the original geographic/streaming stack, but present it at a real
    # quality target instead of the later performance-first profile.
    scene.call("set_quality", "Quality")
    get_viewport().scaling_3d_scale = 1.0
    _scene = scene

    var environment_value = scene.get("environment")
    if environment_value is Environment:
        var environment: Environment = environment_value
        # Graphics-pass recovery: filmic highlight rolloff, restrained grade,
        # and quality-tier bloom. These are image settings, not old gameplay.
        environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
        environment.tonemap_exposure = 1.02
        environment.glow_enabled = true
        environment.glow_intensity = 0.22
        environment.glow_strength = 0.72
        environment.glow_bloom = 0.06
        environment.adjustment_enabled = true
        environment.adjustment_brightness = 1.0
        environment.adjustment_contrast = 1.06
        environment.adjustment_saturation = 1.08
        environment.ambient_light_energy = clampf(environment.ambient_light_energy, 0.62, 0.72)
        environment.ambient_light_sky_contribution = maxf(environment.ambient_light_sky_contribution, 0.30)
        environment.fog_density = minf(environment.fog_density, 0.000016)
        _install_cloud_layer(environment)

    var sun_value = scene.get("sun")
    if sun_value is DirectionalLight3D:
        var sun: DirectionalLight3D = sun_value
        sun.shadow_enabled = true
        sun.directional_shadow_max_distance = maxf(sun.directional_shadow_max_distance, 220.0)
        sun.shadow_bias = minf(sun.shadow_bias, 0.035)

    var buildings_value = scene.get("buildings")
    if buildings_value is JamaicaBuildingStreamer:
        _buildings = buildings_value
        _buildings.quality = "Quality"
        _buildings.draw_distance = 1400.0
        _buildings.max_loaded_cells = maxi(_buildings.max_loaded_cells, 176)
        if not _buildings.cell_ready.is_connected(_on_building_cell_ready):
            _buildings.cell_ready.connect(_on_building_cell_ready)
        # Upgrade any cells that were already present before this bootstrap ran.
        for entry in _buildings._loaded.values():
            _upgrade_building_cell(entry.root)

    _applied = true
    _update_cloud_tint()

func _make_cloud_texture() -> ImageTexture:
    # Ported from the dedicated graphics lane. Sampling around a 3D ring makes
    # the equirectangular longitude seam wrap continuously.
    var noise := FastNoiseLite.new()
    noise.seed = 28194
    noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
    noise.frequency = 0.82
    noise.fractal_type = FastNoiseLite.FRACTAL_FBM
    noise.fractal_octaves = 4
    noise.fractal_lacunarity = 2.0
    noise.fractal_gain = 0.52
    var image := Image.create(512, 256, false, Image.FORMAT_RGB8)
    for y in range(256):
        var latitude := (float(y) / 255.0 - 0.5) * PI
        var ring := cos(latitude)
        for x in range(512):
            var longitude := float(x) / 512.0 * TAU
            var sample := noise.get_noise_3d(cos(longitude) * ring * 3.2, sin(longitude) * ring * 3.2, sin(latitude) * 2.4)
            var wisps := noise.get_noise_3d(cos(longitude) * ring * 7.0 + 19.0, sin(longitude) * ring * 7.0 - 7.0, sin(latitude) * 5.0)
            var cloud := smoothstep(0.02, 0.48, sample + wisps * 0.20)
            cloud *= smoothstep(-0.18, 0.22, sin(latitude))
            image.set_pixel(x, y, Color(cloud * 0.42, cloud * 0.45, cloud * 0.48))
    image.generate_mipmaps()
    return ImageTexture.create_from_image(image)

func _install_cloud_layer(environment: Environment) -> void:
    if environment.sky == null or not environment.sky.sky_material is ProceduralSkyMaterial:
        return
    _sky_material = environment.sky.sky_material as ProceduralSkyMaterial
    _cloud_texture = _make_cloud_texture()
    _sky_material.sky_cover = _cloud_texture
    _sky_material.sky_cover_modulate = Color(0.88, 0.93, 1.0)
    _sky_material.use_debanding = true

func _update_cloud_tint() -> void:
    if _sky_material == null or _scene == null:
        return
    var hour := float(_scene.get("day_hour"))
    var daylight := clampf(sin((hour - 6.0) * PI / 12.0), 0.0, 1.0)
    _sky_material.sky_cover_modulate = Color(0.035, 0.055, 0.10).lerp(Color(0.88, 0.93, 1.0), daylight)

func _on_building_cell_ready(cell: Vector2i, _building_count: int) -> void:
    if _buildings == null:
        return
    var key := "%d:%d" % [cell.x, cell.y]
    if not _buildings._loaded.has(key):
        return
    _upgrade_building_cell(_buildings._loaded[key].root)

func _upgrade_building_cell(root: Node3D) -> void:
    if root == null:
        return
    for child in root.get_children():
        if child is MeshInstance3D:
            child.visibility_range_end = 1650.0
            child.visibility_range_end_margin = 128.0
        elif child is MultiMeshInstance3D and str(child.name).begins_with("ReferenceFacade"):
            # The old source-facade modules were visually useful, but the 100 m
            # cutoff made towns collapse back into plain extruded footprints too
            # quickly. Keep them visible farther without altering geography.
            child.visibility_range_end = 240.0
            child.visibility_range_end_margin = 30.0
