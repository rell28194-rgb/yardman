extends Node
class_name YardmanBetaReferenceAssetRuntime

# Optional private-pack quality layer. Source textures may be absent from the
# public repository; absence is a supported fallback and never changes geometry.
const References = preload("res://scripts/reference_assets.gd")
const TERRAIN_NORMAL_ASSET := "beta2_ucaptain_scrub_grass_normal.ktx"
const WATER_NORMAL_ASSET := "beta2_ucaptain_water_bump.ktx"

var _terrain
var _terrain_normal: Texture2D
var _water_normal: Texture2D
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
    var root := get_parent()
    if root == null:
        return
    _terrain = root.get_node_or_null("JamaicaTerrainStreamer")
    if _terrain == null or not is_instance_valid(_terrain):
        return
    _terrain_normal = References.texture(TERRAIN_NORMAL_ASSET)
    _water_normal = References.texture(WATER_NORMAL_ASSET)
    if not _terrain.tile_ready.is_connected(_on_tile_ready):
        _terrain.tile_ready.connect(_on_tile_ready)
    _apply_ocean_normal()
    for raw: Variant in _terrain._loaded.values():
        if raw is Node3D:
            _apply_terrain_normal(raw)
    _bound = true
    set_process(false)

func _on_tile_ready(tile: Vector2i) -> void:
    if _terrain == null or not is_instance_valid(_terrain):
        return
    var key := _terrain._tile_key(tile.x, tile.y)
    var tile_root = _terrain._loaded.get(key)
    if tile_root is Node3D:
        _apply_terrain_normal(tile_root)
    # Coastline material is shared. Reapplying is cheap and covers a renderer
    # that was created after this runtime first bound.
    _apply_ocean_normal()

func _apply_terrain_normal(tile_root: Node3D) -> void:
    if _terrain_normal == null:
        return
    var land := tile_root.get_node_or_null("RegisteredLand") as MeshInstance3D
    if land == null or land.mesh == null or land.mesh.get_surface_count() == 0:
        return
    var material := land.mesh.surface_get_material(0) as ShaderMaterial
    if material == null:
        return
    material.set_shader_parameter("reference_grass_normal", _terrain_normal)
    material.set_shader_parameter("has_reference_grass_normal", true)
    land.set_meta("beta2_scrub_normal", true)

func _apply_ocean_normal() -> void:
    if _water_normal == null or _terrain == null or not is_instance_valid(_terrain):
        return
    var coastline = _terrain.coastline
    if coastline == null or not is_instance_valid(coastline):
        return
    var material := coastline.water_material as ShaderMaterial
    if material == null:
        return
    material.set_shader_parameter("reference_normal", _water_normal)
    material.set_shader_parameter("has_reference_normal", true)
    coastline.set_meta("beta2_water_normal", true)

static func optional_asset_contract() -> Dictionary:
    return {
        "terrain_normal": TERRAIN_NORMAL_ASSET,
        "water_normal": WATER_NORMAL_ASSET,
        "geometry_mutation": false,
        "collision": false,
        "asset_absent_fallback": true,
    }
