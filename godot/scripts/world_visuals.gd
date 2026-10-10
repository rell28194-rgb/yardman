extends RefCounted
class_name YardmanWorldVisuals

const TERRAIN_SHADER = preload("res://shaders/terrain_surface.gdshader")
const LEAF_SHADER = preload("res://shaders/foliage.gdshader")
const BARK_SHADER = preload("res://shaders/tree_bark.gdshader")
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
    # Filmic mapping preserves bright tropical skies while keeping shaded roads
    # and vegetation legible on phone displays. Glow is gated by quality below.
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

func apply_environment_quality(environment: Environment, profile: String) -> void:
    # Prioritize the image on Quality/Ultra without taxing the lowest tier.
    # Compatibility rendering supports this lightweight glow/grade path.
    var high_quality := profile == "Quality" or profile == "Ultra" or profile == "Custom"
    environment.glow_enabled = high_quality
    environment.glow_intensity = 0.28 if profile == "Ultra" else 0.22
    environment.glow_strength = 0.72
    environment.glow_bloom = 0.06
    environment.adjustment_enabled = true
    environment.adjustment_brightness = 1.0
    environment.adjustment_contrast = 1.06
    environment.adjustment_saturation = 1.08

func update_daylight(hour: float, environment: Environment) -> void:
    var daylight := clampf(sin((hour - 6.0) * PI / 12.0), 0.0, 1.0)
    var golden := clampf(1.0 - daylight * 2.4, 0.0, 1.0)
    if _sun != null:
        _sun.rotation_degrees = Vector3(90.0 - hour * 15.0, -35.0, 0.0)
        _sun.light_energy = lerpf(0.07, 1.24, daylight)
        _sun.light_color = Color(1.0, 0.95, 0.84).lerp(Color(1.0, 0.62, 0.36), golden * daylight)
    environment.ambient_light_energy = lerpf(0.17, 0.72, sqrt(daylight))
    environment.ambient_light_color = Color(0.31, 0.40, 0.59).lerp(Color(0.86, 0.89, 0.93), daylight)
    environment.fog_light_color = Color(0.08, 0.12, 0.20).lerp(Color(0.78, 0.85, 0.86), daylight)
    if _sky_material != null:
        _sky_material.sky_top_color = Color(0.025, 0.05, 0.11).lerp(Color(0.16, 0.39, 0.67), sqrt(daylight))
        _sky_material.sky_horizon_color = Color(0.10, 0.14, 0.22).lerp(Color(0.76, 0.86, 0.91), daylight)

func make_roadside(root: Node3D, segments: Array, tile: Vector2i, tile_size: float, terrain_sampler: Callable = Callable()) -> void:
    var existing := root.get_node_or_null("RoadsideProxy")
    if existing != null:
        root.remove_child(existing)
        existing.queue_free()
    var roadside := Node3D.new()
    roadside.name = "RoadsideProxy"
    root.add_child(roadside)
    var records := _unique_roads(segments)
    var buckets := _road_buckets(records)
    var occupied: Dictionary = {}
    var groups: Dictionary = {}
    var tile_origin := Vector2(float(tile.x) * tile_size, float(tile.y) * tile_size)
    var count := 0
    for record: Dictionary in records:
        if count >= MAX_PLANTS:
            break
        var seed_value: int = record.seed
        if seed_value % 3 != 0:
            continue
        var delta: Vector2 = record.b - record.a
        var length_m := delta.length()
        if length_m < 0.5:
            continue
        var direction := delta / length_m
        var perpendicular := Vector2(-direction.y, direction.x)
        var repetitions := clampi(int(ceil(length_m / 55.0)), 1, 8)
        for repetition in range(repetitions):
            for side in [-1.0, 1.0]:
                var seed_point := posmod(seed_value + repetition * 7927 + (9137 if side > 0.0 else 0), 2147483647)
                var fraction := (float(repetition) + 0.20 + float(seed_point % 601) / 1000.0) / float(repetitions)
                var distance := float(record.width) * 0.5 + 7.0 + float(seed_point % 2100) / 100.0
                var point: Vector2 = record.a + delta * fraction + perpendicular * distance * side
                if not _inside_tile(point, tile, tile_size) or _inside_road(point, buckets, records, 2.5):
                    continue
                var occupancy := Vector2i(int(floor(point.x / 7.0)), int(floor(point.y / 7.0)))
                if occupied.has(occupancy):
                    continue
                var height := float(terrain_sampler.call(point.x, point.y)) if terrain_sampler.is_valid() else lerpf(float(record.ha), float(record.hb), fraction)
                # A road tile may arrive before terrain. Missing tiles and sea
                # are not permission to plant trees on a floating road height.
                if is_nan(height) or is_inf(height) or height < 1.35:
                    continue
                var species := "palm" if height < 220.0 and seed_point % 5 != 0 else "broadleaf"
                if seed_point % 7 == 0:
                    species = "shrub"
                var scale_value := 0.72 + float(seed_point % 650) / 1000.0
                if species == "shrub":
                    scale_value *= 0.36
                var basis := Basis(Vector3.UP, float(seed_point % 6283) / 1000.0).scaled(Vector3.ONE * scale_value)
                var position_local := Vector3(point.x - tile_origin.x, height, point.y - tile_origin.y)
                var cell := Vector2i(int(floor(position_local.x / CULL_CELL_M)), int(floor(position_local.z / CULL_CELL_M)))
                var key := "%d:%d:%s" % [cell.x, cell.y, species]
                if not groups.has(key):
                    groups[key] = {"species": species, "cell": cell, "plants": []}
                groups[key].plants.append({"transform": Transform3D(basis, position_local), "seed": seed_point})
                occupied[occupancy] = true
                count += 1
                if count >= MAX_PLANTS:
                    break
            if count >= MAX_PLANTS:
                break
    for group: Dictionary in groups.values():
        _make_plant_cell(roadside, group, tile_origin)
    roadside.set_meta("plant_count", count)
    apply_roadside_quality(root)

func apply_roadside_quality(tile_root: Node3D) -> void:
    var roadside := tile_root.get_node_or_null("RoadsideProxy") as Node3D
    if roadside == null:
        return
    var count := int(roadside.get_meta("plant_count", 0))
    var budget := clampi(int(settings().trees), 40, MAX_PLANTS)
    var ratio := minf(1.0, float(budget) / float(maxi(1, count)))
    for cell: MultiMeshInstance3D in roadside.get_children():
        var full_count := cell.multimesh.instance_count
        cell.multimesh.visible_instance_count = mini(full_count, maxi(1, int(ceil(float(full_count) * ratio))))
        cell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if bool(settings().shadows) and not bool(cell.get_meta("grass", false)) else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func _unique_roads(segments: Array) -> Array[Dictionary]:
    var records: Array[Dictionary] = []
    var seen: Dictionary = {}
    for item in segments:
        if not item is Array or item.size() < 11:
            continue
        var segment: Array = item
        var key := "%s:%s:%s:%s:%s:%s" % [str(segment[7]), str(segment[8]), str(segment[0]), str(segment[1]), str(segment[2]), str(segment[3])]
        if seen.has(key):
            continue
        seen[key] = true
        records.append({"a": Vector2(float(segment[0]), float(segment[1])), "b": Vector2(float(segment[2]), float(segment[3])),
            "width": float(segment[4]), "ha": float(segment[9]), "hb": float(segment[10]), "seed": key.hash() & 0x7fffffff})
    # Stable per-cell prefixes let profile changes change density without
    # moving surviving vegetation or depending on mesh triangulation order.
    records.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.seed) < int(b.seed))
    return records

func _road_buckets(records: Array[Dictionary]) -> Dictionary:
    var buckets: Dictionary = {}
    for i in range(records.size()):
        var road: Dictionary = records[i]
        var padding := float(road.width) * 0.5 + 4.0
        var a: Vector2 = road.a
        var b: Vector2 = road.b
        var min_cell := Vector2i(int(floor((minf(a.x, b.x) - padding) / ROAD_BUCKET_M)), int(floor((minf(a.y, b.y) - padding) / ROAD_BUCKET_M)))
        var max_cell := Vector2i(int(floor((maxf(a.x, b.x) + padding) / ROAD_BUCKET_M)), int(floor((maxf(a.y, b.y) + padding) / ROAD_BUCKET_M)))
        for z in range(min_cell.y, max_cell.y + 1):
            for x in range(min_cell.x, max_cell.x + 1):
                var key := Vector2i(x, z)
                if not buckets.has(key):
                    buckets[key] = []
                buckets[key].append(i)
    return buckets

func _inside_road(point: Vector2, buckets: Dictionary, records: Array[Dictionary], margin: float) -> bool:
    var cell := Vector2i(int(floor(point.x / ROAD_BUCKET_M)), int(floor(point.y / ROAD_BUCKET_M)))
    for index in buckets.get(cell, []):
        var road: Dictionary = records[int(index)]
        var a: Vector2 = road.a
        var delta: Vector2 = road.b - a
        var t := clampf((point - a).dot(delta) / maxf(delta.length_squared(), 0.000001), 0.0, 1.0)
        if point.distance_squared_to(a + delta * t) < pow(float(road.width) * 0.5 + margin, 2.0):
            return true
    return false

func _inside_tile(point: Vector2, tile: Vector2i, tile_size: float) -> bool:
    return int(floor(point.x / tile_size)) == tile.x and int(floor(point.y / tile_size)) == tile.y

func _make_plant_cell(roadside: Node3D, group: Dictionary, tile_origin: Vector2) -> void:
    var species: String = group.species
    if not _plant_meshes.has(species):
        _plant_meshes[species] = _make_palm_mesh() if species == "palm" else _make_broadleaf_mesh()
    var cell: Vector2i = group.cell
    var center := Vector3((float(cell.x) + 0.5) * CULL_CELL_M, 0.0, (float(cell.y) + 0.5) * CULL_CELL_M)
    var plants: Array = group.plants
    var average_height := 0.0
    for plant: Dictionary in plants:
        average_height += plant.transform.origin.y
    center.y = average_height / float(plants.size())
    var multi := MultiMesh.new()
    multi.transform_format = MultiMesh.TRANSFORM_3D
    multi.use_colors = true
    multi.use_custom_data = true
    multi.mesh = _plant_meshes[species]
    multi.instance_count = plants.size()
    for i in range(plants.size()):
        var transform: Transform3D = plants[i].transform
        transform.origin -= center
        multi.set_instance_transform(i, transform)
        multi.set_instance_color(i, Color.WHITE)
        var seed_point := int(plants[i].seed)
        var canonical_point := Vector2(plants[i].transform.origin.x + tile_origin.x, plants[i].transform.origin.z + tile_origin.y)
        multi.set_instance_custom_data(i, Color(float(seed_point % 997) / 997.0, float(seed_point % 421) / 421.0, _regional_dryness(canonical_point), 1.0))
    var instance := MultiMeshInstance3D.new()
    instance.name = "Plants_%d_%d_%s" % [cell.x, cell.y, species]
    instance.position = center
    instance.multimesh = multi
    instance.visibility_range_end = 1000.0 if species != "shrub" else 470.0
    roadside.add_child(instance)
    # Small grass tufts at existing off-road plant anchors add a near ground
    # layer, with their own short cull distance and no alpha-blended planes.
    if not _plant_meshes.has("grass"):
        _plant_meshes.grass = _make_grass_mesh()
    var grass_multi := MultiMesh.new()
    grass_multi.transform_format = MultiMesh.TRANSFORM_3D
    grass_multi.use_colors = true
    grass_multi.use_custom_data = true
    grass_multi.mesh = _plant_meshes.grass
    grass_multi.instance_count = plants.size()
    for i in range(plants.size()):
        var transform: Transform3D = plants[i].transform
        transform.basis = transform.basis.scaled(Vector3.ONE * 1.2)
        transform.origin -= center
        grass_multi.set_instance_transform(i, transform)
        grass_multi.set_instance_color(i, Color.WHITE)
        grass_multi.set_instance_custom_data(i, multi.get_instance_custom_data(i))
    var grass := MultiMeshInstance3D.new()
    grass.name = instance.name + "_Grass"
    grass.position = center
    grass.multimesh = grass_multi
    grass.visibility_range_end = 150.0
    grass.set_meta("grass", true)
    roadside.add_child(grass)

func _surface() -> SurfaceTool:
    var surface := SurfaceTool.new()
    surface.begin(Mesh.PRIMITIVE_TRIANGLES)
    return surface

func _triangle(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, color: Color) -> void:
    surface.set_color(color)
    for vertex: Vector3 in [a, b, c]:
        surface.add_vertex(vertex)

func _join_surfaces(bark: SurfaceTool, leaves: SurfaceTool, leaf_tint: Color, wind: float) -> ArrayMesh:
    bark.generate_normals()
    var mesh := bark.commit()
    var bark_material := ShaderMaterial.new()
    bark_material.shader = BARK_SHADER
    mesh.surface_set_material(0, bark_material)
    leaves.generate_normals()
    leaves.commit(mesh)
    var material := ShaderMaterial.new()
    material.shader = LEAF_SHADER
    material.set_shader_parameter("tint", leaf_tint)
    material.set_shader_parameter("wind_strength", wind)
    mesh.surface_set_material(1, material)
    return mesh

func _tube(surface: SurfaceTool, a: Vector3, b: Vector3, bottom: float, top: float, color: Color, sides: int = 10) -> void:
    var direction := (b - a).normalized()
    var axis := direction.cross(Vector3.FORWARD).normalized()
    if axis.length_squared() < 0.1:
        axis = Vector3.RIGHT
    var other := direction.cross(axis).normalized()
    for i in range(sides):
        var first := axis * cos(float(i) * TAU / float(sides)) + other * sin(float(i) * TAU / float(sides))
        var second := axis * cos(float(i + 1) * TAU / float(sides)) + other * sin(float(i + 1) * TAU / float(sides))
        _triangle(surface, a + first * bottom, b + first * top, a + second * bottom, color)
        _triangle(surface, a + second * bottom, b + first * top, b + second * top, color)

func _make_palm_mesh() -> ArrayMesh:
    var bark := _surface()
    var leaves := _surface()
    var crown := Vector3(0.58, 8.2, 0.25)
    for level in range(12):
        var t0 := float(level) / 12.0
        var t1 := float(level + 1) / 12.0
        var a := Vector3(crown.x * t0 * t0, crown.y * t0, crown.z * t0 * t0)
        var b := Vector3(crown.x * t1 * t1, crown.y * t1, crown.z * t1 * t1)
        _tube(bark, a, b, lerpf(0.26, 0.13, t0), lerpf(0.26, 0.13, t1), Color(0.43, 0.37, 0.26, 0.0), 10)
    for frond in range(11):
        var angle := float(frond) * TAU / 11.0 + sin(float(frond) * 2.31) * 0.18
        var outward := Vector3(cos(angle), 0, sin(angle))
        var sideways := Vector3(-sin(angle), 0, cos(angle))
        var length_m := 3.8 + sin(float(frond) * 1.71) * 0.8
        var uplift := 1.15 if frond % 3 == 0 else 0.45
        var previous := crown
        for step in range(1, 9):
            var t := float(step) / 8.0
            var spine := crown + outward * length_m * t + Vector3.UP * (sin(t * PI) * uplift - t * t * 1.45)
            _tube(leaves, previous, spine, 0.025, 0.016, Color(0.83, 1.0, 0.55, t), 4)
            var spread := sin(t * PI) * 0.85 + 0.08
            for side in [-1.0, 1.0]:
                var leaf_tip: Vector3 = spine + sideways * spread * side + outward * 0.34 + Vector3.DOWN * (0.18 + t * 0.2)
                var leaf_root := spine - outward * 0.16
                var fold: Vector3 = spine + sideways * spread * 0.48 * side + outward * 0.13 + Vector3.UP * 0.06
                var color := Color(0.77 + t * 0.12, 0.89 + t * 0.1, 0.65, t)
                _triangle(leaves, leaf_root, fold, leaf_tip, color)
                _triangle(leaves, leaf_root, leaf_tip, spine + outward * 0.12, Color(color.r * 0.85, color.g * 0.88, color.b * 0.87, t))
            previous = spine
    return _join_surfaces(bark, leaves, Color(0.32, 0.46, 0.14), 0.16)

func _ellipsoid(surface: SurfaceTool, center: Vector3, radii: Vector3, seed_value: int) -> void:
    for row in range(7):
        var lat_a := -PI * 0.5 + float(row) * PI / 7.0
        var lat_b := -PI * 0.5 + float(row + 1) * PI / 7.0
        for column in range(11):
            var angle_a := float(column) * TAU / 11.0
            var angle_b := float(column + 1) * TAU / 11.0
            var a := center + Vector3(cos(angle_a) * cos(lat_a), sin(lat_a), sin(angle_a) * cos(lat_a)) * radii
            var b := center + Vector3(cos(angle_b) * cos(lat_a), sin(lat_a), sin(angle_b) * cos(lat_a)) * radii
            var c := center + Vector3(cos(angle_a) * cos(lat_b), sin(lat_b), sin(angle_a) * cos(lat_b)) * radii
            var d := center + Vector3(cos(angle_b) * cos(lat_b), sin(lat_b), sin(angle_b) * cos(lat_b)) * radii
            var variation := 0.75 + float(posmod(seed_value + row * 19 + column * 7, 27)) / 70.0
            var color := Color(variation, variation, variation * 0.87, 0.25)
            # Slightly irregular crown lobes, rather than an unchanged sphere
            # repeated eight times, keep broadleaf silhouettes organic.
            a = center + (a - center) * (0.91 + float(posmod(seed_value + row * 11 + column * 13, 19)) / 95.0)
            b = center + (b - center) * (0.91 + float(posmod(seed_value + row * 11 + (column + 1) * 13, 19)) / 95.0)
            c = center + (c - center) * (0.91 + float(posmod(seed_value + (row + 1) * 11 + column * 13, 19)) / 95.0)
            d = center + (d - center) * (0.91 + float(posmod(seed_value + (row + 1) * 11 + (column + 1) * 13, 19)) / 95.0)
            _triangle(surface, a, c, b, color)
            _triangle(surface, b, c, d, color)
    for leaf in range(34):
        var angle := float(leaf) * 2.399963
        var altitude := -0.62 + float(leaf % 13) / 12.0 * 1.4
        var direction := Vector3(cos(angle) * cos(altitude), sin(altitude), sin(angle) * cos(altitude))
        var root := center + direction * radii * 0.93
        var out := direction * 0.33
        var side := direction.cross(Vector3.UP).normalized() * 0.12
        var fold := root + out * 0.53 + Vector3.UP * 0.025
        var color := Color(0.83 + float(leaf % 5) * 0.036, 0.95, 0.74, 0.45)
        _triangle(surface, root, root + out * 0.44 + side, fold, color)
        _triangle(surface, root + out * 0.44 + side, root + out, fold, color)
        _triangle(surface, root, fold, root + out * 0.44 - side, Color(color.r * 0.89, color.g * 0.91, color.b * 0.90, 0.45))
        _triangle(surface, root + out * 0.44 - side, fold, root + out, color)

func _make_broadleaf_mesh() -> ArrayMesh:
    var bark := _surface()
    var leaves := _surface()
    _tube(bark, Vector3.ZERO, Vector3(0.17, 5.1, -0.1), 0.33, 0.14, Color(0.37, 0.30, 0.23, 0.0))
    for branch in range(7):
        var angle := float(branch) * TAU / 7.0
        var center := Vector3(cos(angle) * 1.8, 4.8 + float(branch % 3) * 0.7, sin(angle) * 1.8)
        _tube(bark, Vector3(0.1, 3.1 + float(branch % 2) * 0.5, 0), center, 0.10, 0.028, Color(0.35, 0.29, 0.22, 0.0), 6)
        _ellipsoid(leaves, center, Vector3(1.65, 1.4, 1.55), branch * 73)
    _ellipsoid(leaves, Vector3(0.15, 6.4, -0.1), Vector3(1.8, 1.6, 1.8), 997)
    return _join_surfaces(bark, leaves, Color(0.25, 0.38, 0.13), 0.12)

func _make_grass_mesh() -> ArrayMesh:
    var surface := _surface()
    for blade in range(14):
        var angle := float(blade) * TAU / 14.0
        var side := Vector3(cos(angle), 0, sin(angle))
        var start := Vector3(sin(float(blade) * 1.8) * 0.28, 0.015, cos(float(blade) * 2.0) * 0.28)
        var middle := start + Vector3.UP * (0.23 + float(blade % 3) * 0.05)
        var tip := start + Vector3.UP * (0.45 + float(blade % 5) * 0.06) + side * 0.23
        _triangle(surface, start - side * 0.028, start + side * 0.028, middle, Color(0.79, 0.80, 0.6, 0.0))
        _triangle(surface, start + side * 0.028, tip, middle, Color(1.0, 1.0, 0.83, 1.0))
    surface.generate_normals()
    var mesh := surface.commit()
    var material := ShaderMaterial.new()
    material.shader = LEAF_SHADER
    material.set_shader_parameter("tint", Color(0.35, 0.43, 0.13))
    material.set_shader_parameter("wind_strength", 0.07)
    mesh.surface_set_material(0, material)
    return mesh

