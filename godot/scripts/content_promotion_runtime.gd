extends Node
class_name YardmanContentPromotionRuntime

const References = preload("res://scripts/reference_assets.gd")

var _detail: Node
var _water: Node
var _packs: Node
var _fleet: Node

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    call_deferred("_bind_runtime")

func _bind_runtime() -> void:
    _detail = get_node_or_null("/root/WorldDetail")
    _water = get_node_or_null("/root/RunningWater")
    _packs = get_node_or_null("/root/ContentPacks")
    _fleet = get_node_or_null("/root/RemoteFleet")
    if _detail == null or _water == null or _packs == null or _fleet == null:
        call_deferred("_bind_runtime")
        return

    var pack_cb := Callable(self, "_on_pack_installed")
    if _packs.has_signal("pack_installed") and not _packs.is_connected("pack_installed", pack_cb):
        _packs.connect("pack_installed", pack_cb)
    var fleet_cb := Callable(self, "_on_fleet_installed")
    if _fleet.has_signal("installed") and not _fleet.is_connected("installed", fleet_cb):
        _fleet.connect("installed", fleet_cb)

    _refresh_reference_media(false)
    _refresh_water_material()

func _on_fleet_installed() -> void:
    # The private owner media pack already contains the first high-detail palm,
    # tree, bush and water media. Promote those immediately after its verified
    # extraction; no APK reinstall or game restart is required.
    References.invalidate_runtime_caches()
    _refresh_reference_media(true)
    _refresh_water_material()

func _on_pack_installed(pack_id: String, _version: int) -> void:
    References.invalidate_runtime_caches()
    match pack_id:
        "world-detail":
            _refresh_reference_media(true)
        "hydrology":
            _refresh_water_material()
            _reload_hydrology()
        "atmosphere":
            _refresh_water_material()
        _:
            pass

func _refresh_reference_media(rebuild_cells: bool) -> void:
    if _detail == null:
        return
    var meshes: Dictionary = _detail.get("_meshes") as Dictionary
    var reference_cache: Dictionary = _detail.get("_reference_mesh_cache") as Dictionary
    reference_cache.clear()

    # Erasing the key allows WorldDetail to resolve the newly installed media.
    # A null sentinel prevents its deliberately simple emergency fallback from
    # becoming the normal Jamaica tree canopy before the real pack is present.
    for binding: Array in [
        ["tree", "road_tree_near.glb"],
        ["tree_far", "road_tree.glb"],
        ["palm", "road_palm.glb"],
        ["palm_far", "road_palm_lod.glb"],
        ["bush", "road_bush.glb"],
    ]:
        var species: String = str(binding[0])
        var filename: String = str(binding[1])
        meshes.erase(species)
        if not References.exact_asset_exists(filename):
            meshes[species] = null
    _detail.set("_meshes", meshes)
    _detail.set("_reference_mesh_cache", reference_cache)

    if rebuild_cells:
        _rebuild_detail_cells()

func _rebuild_detail_cells() -> void:
    if _detail == null:
        return
    var cells: Dictionary = _detail.get("_cells") as Dictionary
    for raw_node: Variant in cells.values():
        var node: Node = raw_node as Node
        if is_instance_valid(node):
            node.queue_free()
    cells.clear()
    _detail.set("_cells", cells)
    _detail.set("_building", {})
    _detail.set("_queue", [])
    _detail.set("_last_center", Vector2i(999999, 999999))
    _detail.set("_last_quality", "")
    _detail.call_deferred("_refresh_cells", true)

func _refresh_water_material() -> void:
    if _water == null:
        return
    _water.call("_make_material")
    var loaded: Dictionary = _water.get("_loaded") as Dictionary
    for raw_node: Variant in loaded.values():
        if raw_node is MeshInstance3D and is_instance_valid(raw_node):
            var instance := raw_node as MeshInstance3D
            if instance.mesh != null and instance.mesh.get_surface_count() > 0:
                instance.mesh.surface_set_material(0, _water.get("_material") as Material)

func _reload_hydrology() -> void:
    if _water == null:
        return
    var loaded: Dictionary = _water.get("_loaded") as Dictionary
    for raw_node: Variant in loaded.values():
        if raw_node is Node and is_instance_valid(raw_node):
            (raw_node as Node).queue_free()
    loaded.clear()
    _water.set("_loaded", loaded)
    _water.set("_manifest", {})
    _water.set("_tile_files", {})
    _water.set("_root", "")
    if bool(_water.call("_load_manifest")):
        _water.call_deferred("_queue_loaded_terrain_tiles")
