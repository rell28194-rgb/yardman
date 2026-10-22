extends Node
class_name YardmanBetaReferenceAssetRuntime

# Optional private-pack quality layer. Source textures may be absent from the
# public repository; absence is a supported fallback and never changes geometry.
const References = preload("res://scripts/reference_assets.gd")
const TERRAIN_NORMAL_ASSET := "beta2_ucaptain_scrub_grass_normal.ktx"
const TERRAIN_ALT_ROCK_ASSET := "ground_rock_alternate.png"
const WATER_NORMAL_ASSET := "beta2_ucaptain_water_bump.ktx"
const BUILDING_CONCRETE_ASSET := "building_concrete.png"

var _terrain
var _buildings
var _terrain_normal: Texture2D
var _terrain_alt_rock: Texture2D
var _water_normal: Texture2D
var _building_concrete: Texture2D
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
    _water_normal = References.texture(WATER_NORMAL_ASSET)
    _building_concrete = References.texture(BUILDING_CONCRETE_ASSET)
    if not _terrain.tile_ready.is_connected(_on_tile_ready):
        _terrain.tile_ready.connect(_on_tile_ready)
    _apply_ocean_normal()
    _apply_building_concrete()
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
    _apply_ocean_normal()
    _apply_building_concrete()

func _apply_terrain_detail(tile_root: Node3D) -> void:
    if _terrain_normal == null and _terrain_alt_rock == null:
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

func _apply_ocean_normal() -> void:
    if _water_normal == null or _terrain == null or not is_instance_valid(_terrain):
        return
    var coastline: Variant = _terrain.coastline
    if coastline == null or not is_instance_valid(coastline):
        return
    var material := coastline.water_material as ShaderMaterial
    if material == null:
        return
    material.set_shader_parameter("reference_normal", _water_normal)
    material.set_shader_parameter("has_reference_normal", true)
    coastline.set_meta("beta2_water_normal", true)

func _apply_building_concrete() -> void:
    if _building_concrete == null or _buildings == null or not is_instance_valid(_buildings):
        return
    var material := _buildings.get("_wall_material") as ShaderMaterial
    if material == null:
        return
    material.set_shader_parameter("reference_concrete", _building_concrete)
    material.set_shader_parameter("has_reference_concrete", true)
    _buildings.set_meta("beta1_concrete_family", true)

static func optional_asset_contract() -> Dictionary:
    return {
        "terrain_normal": TERRAIN_NORMAL_ASSET,
        "terrain_alt_rock": TERRAIN_ALT_ROCK_ASSET,
        "water_normal": WATER_NORMAL_ASSET,
        "building_concrete": BUILDING_CONCRETE_ASSET,
        "geometry_mutation": false,
        "collision": false,
        "extra_draw_calls": false,
        "alternate_rock_extra_samples": 1,
        "asset_absent_fallback": true,
    }
