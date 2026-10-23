extends Node
class_name YardmanBetaReferenceAssetRuntime

# Optional private-pack quality layer. Source textures may be absent from the
# public repository; absence is a supported fallback and never changes geometry.
const References = preload("res://scripts/reference_assets.gd")
const TERRAIN_NORMAL_ASSET := "beta2_ucaptain_scrub_grass_normal.ktx"
const TERRAIN_ALT_ROCK_ASSET := "ground_rock_alternate.png"
const TERRAIN_SOIL_DETAIL_ASSET := "beta2_survival_woodsground_diffuse.ktx"
const WATER_NORMAL_ASSET := "beta2_ucaptain_water_bump.ktx"
const WATER_ALT_FOAM_ASSET := "water_foam_japan.png"
const BUILDING_CONCRETE_ASSET := "building_concrete.png"
const BUILDING_STONE_ALT_ASSET := "building_stonewall_04.png"
const BUILDING_STONE_ALT_02_ASSET := "building_stonewall_02.png"
const BUILDING_TIMBER_01_ASSET := "building_timber_01.png"
const BUILDING_TIMBER_03_ASSET := "building_timber_03.png"
const BUILDING_TIMBER_04_ASSET := "building_timber_04.png"
const BUILDING_STUCCO_NATURAL_ASSET := "building_stucco_natural.png"
const BUILDING_STUCCO_RED_ASSET := "building_stucco_red.png"
const BUILDING_STUCCO_YELLOW_ASSET := "building_stucco_yellow.png"

var _terrain
var _buildings
var _terrain_normal: Texture2D
var _terrain_alt_rock: Texture2D
var _terrain_soil_detail: Texture2D
var _water_normal: Texture2D
var _water_alt_foam: Texture2D
var _building_concrete: Texture2D
var _building_stone_alt: Texture2D
var _building_stone_alt_02: Texture2D
var _building_timber_01: Texture2D
var _building_timber_03: Texture2D
var _building_timber_04: Texture2D
var _building_stucco_natural: Texture2D
var _building_stucco_red: Texture2D
var _building_stucco_yellow: Texture2D
var _clock := 0.0
var _bound := false

func _ready() -> void:
    call_deferred("_try_bind")

func _process(delta: float) -> void:
    if _bound:
        return
    _clock += delta
    if _clock < 0.35:
        return
    _clock = 0.0
    _try_bind()

func _exit_tree() -> void:
    if _terrain != null and is_instance_valid(_terrain) and _terrain.tile_ready.is_connected(_on_tile_ready):
        _terrain.tile_ready.disconnect(_on_tile_ready)

func _try_bind() -> void:
    var root: Node = get_parent()
    if root == null:
        return
    _terrain = root.get_node_or_null("JamaicaTerrainStreamer")
    _buildings = root.get_node_or_null("JamaicaBuildingStreamer")
    if _terrain == null or not is_instance_valid(_terrain):
        return
    _terrain_normal = References.texture(TERRAIN_NORMAL_ASSET)
    _terrain_alt_rock = References.texture(TERRAIN_ALT_ROCK_ASSET)
    _terrain_soil_detail = References.texture(TERRAIN_SOIL_DETAIL_ASSET)
    _water_normal = References.texture(WATER_NORMAL_ASSET)
    _water_alt_foam = References.texture(WATER_ALT_FOAM_ASSET)
    _building_concrete = References.texture(BUILDING_CONCRETE_ASSET)
    _building_stone_alt = References.texture(BUILDING_STONE_ALT_ASSET)
    _building_stone_alt_02 = References.texture(BUILDING_STONE_ALT_02_ASSET)
    _building_timber_01 = References.texture(BUILDING_TIMBER_01_ASSET)
    _building_timber_03 = References.texture(BUILDING_TIMBER_03_ASSET)
    _building_timber_04 = References.texture(BUILDING_TIMBER_04_ASSET)
    _building_stucco_natural = References.texture(BUILDING_STUCCO_NATURAL_ASSET)
    _building_stucco_red = References.texture(BUILDING_STUCCO_RED_ASSET)
    _building_stucco_yellow = References.texture(BUILDING_STUCCO_YELLOW_ASSET)
    if not _terrain.tile_ready.is_connected(_on_tile_ready):
        _terrain.tile_ready.connect(_on_tile_ready)
    _apply_ocean_detail()
    _apply_building_materials()
    for raw: Variant in _terrain._loaded.values():
        if raw is Node3D:
            _apply_terrain_detail(raw as Node3D)
    _bound = true
    set_process(false)

func _on_tile_ready(tile: Vector2i) -> void:
    if _terrain == null or not is_instance_valid(_terrain):
        return
    var key: String = str(_terrain._tile_key(tile.x, tile.y))
    var tile_root: Variant = _terrain._loaded.get(key)
    if tile_root is Node3D:
        _apply_terrain_detail(tile_root as Node3D)
    # Coastline/building materials are shared. Reapplying is cheap and covers a
    # renderer created after this runtime first bound.
    _apply_ocean_detail()
    _apply_building_materials()

func _apply_terrain_detail(tile_root: Node3D) -> void:
    if _terrain_normal == null and _terrain_alt_rock == null and _terrain_soil_detail == null:
        return
    var land := tile_root.get_node_or_null("RegisteredLand") as MeshInstance3D
    if land == null or land.mesh == null or land.mesh.get_surface_count() == 0:
        return
    var material := land.mesh.surface_get_material(0) as ShaderMaterial
    if material == null:
        return
    if _terrain_normal != null:
        material.set_shader_parameter("reference_grass_normal", _terrain_normal)
        material.set_shader_parameter("has_reference_grass_normal", true)
        land.set_meta("beta2_scrub_normal", true)
    if _terrain_alt_rock != null:
        material.set_shader_parameter("reference_rock_alternate", _terrain_alt_rock)
        material.set_shader_parameter("has_reference_rock_alternate", true)
        land.set_meta("beta1_alternate_rock", true)
    if _terrain_soil_detail != null:
        material.set_shader_parameter("reference_soil_detail", _terrain_soil_detail)
        material.set_shader_parameter("has_reference_soil_detail", true)
        land.set_meta("beta2_survival_soil_detail", true)

func _apply_ocean_detail() -> void:
    if (_water_normal == null and _water_alt_foam == null) or _terrain == null or not is_instance_valid(_terrain):
        return
    var coastline: Variant = _terrain.coastline
    if coastline == null or not is_instance_valid(coastline):
        return
    var material := coastline.water_material as ShaderMaterial
    if material == null:
        return
    if _water_normal != null:
        material.set_shader_parameter("reference_normal", _water_normal)
        material.set_shader_parameter("has_reference_normal", true)
        coastline.set_meta("beta2_water_normal", true)
    if _water_alt_foam != null:
        material.set_shader_parameter("reference_foam_alternate", _water_alt_foam)
        material.set_shader_parameter("has_reference_foam_alternate", true)
        coastline.set_meta("beta1_alternate_foam", true)

func _apply_building_materials() -> void:
    if _buildings == null or not is_instance_valid(_buildings):
        return
    if _building_concrete == null and _building_stone_alt == null and _building_stone_alt_02 == null \
            and _building_timber_01 == null and _building_timber_03 == null and _building_timber_04 == null \
            and _building_stucco_natural == null and _building_stucco_red == null and _building_stucco_yellow == null:
        return
    var material := _buildings.get("_wall_material") as ShaderMaterial
    if material == null:
        return
    if _building_concrete != null:
        material.set_shader_parameter("reference_concrete", _building_concrete)
        material.set_shader_parameter("has_reference_concrete", true)
        _buildings.set_meta("beta1_concrete_family", true)
    if _building_stone_alt != null:
        material.set_shader_parameter("reference_stone_alternate", _building_stone_alt)
        material.set_shader_parameter("has_reference_stone_alternate", true)
        _buildings.set_meta("beta1_stone_alternate_detail", true)
    if _building_stone_alt_02 != null:
        material.set_shader_parameter("reference_stone_alternate_02", _building_stone_alt_02)
        material.set_shader_parameter("has_reference_stone_alternate_02", true)
        _buildings.set_meta("beta1_stone_alternate_02_detail", true)
    if _building_timber_01 != null:
        material.set_shader_parameter("reference_timber_01", _building_timber_01)
        material.set_shader_parameter("has_reference_timber_01", true)
        _buildings.set_meta("beta1_timber_01_detail", true)
    if _building_timber_03 != null:
        material.set_shader_parameter("reference_timber_03", _building_timber_03)
        material.set_shader_parameter("has_reference_timber_03", true)
        _buildings.set_meta("beta1_timber_03_detail", true)
    if _building_timber_04 != null:
        material.set_shader_parameter("reference_timber_04", _building_timber_04)
        material.set_shader_parameter("has_reference_timber_04", true)
        _buildings.set_meta("beta1_timber_04_detail", true)
    if _building_stucco_natural != null:
        material.set_shader_parameter("reference_stucco_natural", _building_stucco_natural)
        material.set_shader_parameter("has_reference_stucco_natural", true)
        _buildings.set_meta("beta1_stucco_natural_detail", true)
    if _building_stucco_red != null:
        material.set_shader_parameter("reference_stucco_red", _building_stucco_red)
        material.set_shader_parameter("has_reference_stucco_red", true)
        _buildings.set_meta("beta1_stucco_red_family", true)
    if _building_stucco_yellow != null:
        material.set_shader_parameter("reference_stucco_yellow", _building_stucco_yellow)
        material.set_shader_parameter("has_reference_stucco_yellow", true)
        _buildings.set_meta("beta1_stucco_yellow_family", true)

static func optional_asset_contract() -> Dictionary:
    return {
        "terrain_normal": TERRAIN_NORMAL_ASSET,
        "terrain_alt_rock": TERRAIN_ALT_ROCK_ASSET,
        "terrain_soil_detail": TERRAIN_SOIL_DETAIL_ASSET,
        "water_normal": WATER_NORMAL_ASSET,
        "water_alt_foam": WATER_ALT_FOAM_ASSET,
        "building_concrete": BUILDING_CONCRETE_ASSET,
        "building_stone_alternate": BUILDING_STONE_ALT_ASSET,
        "building_stone_alternate_02": BUILDING_STONE_ALT_02_ASSET,
        "building_timber_01": BUILDING_TIMBER_01_ASSET,
        "building_timber_03": BUILDING_TIMBER_03_ASSET,
        "building_timber_04": BUILDING_TIMBER_04_ASSET,
        "building_stucco_natural": BUILDING_STUCCO_NATURAL_ASSET,
        "building_stucco_red": BUILDING_STUCCO_RED_ASSET,
        "building_stucco_yellow": BUILDING_STUCCO_YELLOW_ASSET,
        "geometry_mutation": false,
        "collision": false,
        "extra_draw_calls": false,
        "palette_family_count_mutation": false,
        "alternate_rock_extra_samples": 1,
        "soil_detail_extra_samples": 1,
        "alternate_foam_extra_samples": 1,
        "painted_stucco_extra_samples_per_fragment": 1,
        "stone_alternate_extra_samples_per_fragment": 1,
        "stone_family_max_samples_per_fragment": 1,
        "timber_family_max_samples_per_fragment": 1,
        "asset_absent_fallback": true,
    }
