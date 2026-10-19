extends Node

# One-shot map-first presentation bootstrap. This branch is deliberately about
# the Jamaica world itself; it does not add AI, jobs, traffic or placeholder
# vehicle systems.
var _applied := false
var _buildings: JamaicaBuildingStreamer

func _ready() -> void:
    set_process(true)

func _process(_delta: float) -> void:
    if _applied:
        set_process(false)
        return
    var scene := get_tree().current_scene
    if scene == null or not scene.has_method("set_quality"):
        return

    scene.call("set_quality", "Quality")
    get_viewport().scaling_3d_scale = 1.0

    var environment_value = scene.get("environment")
    if environment_value is Environment:
        var environment: Environment = environment_value
        environment.tonemap_exposure = 1.03
        environment.ambient_light_energy = clampf(environment.ambient_light_energy, 0.62, 0.72)
        environment.ambient_light_sky_contribution = maxf(environment.ambient_light_sky_contribution, 0.30)
        environment.fog_density = minf(environment.fog_density, 0.000016)

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
        for entry in _buildings._loaded.values():
            _upgrade_building_cell(entry.root)

    _applied = true
    set_process(false)

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
            child.visibility_range_end = 240.0
            child.visibility_range_end_margin = 30.0
