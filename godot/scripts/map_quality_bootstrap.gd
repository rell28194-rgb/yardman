extends Node

# Small, one-shot visual bootstrap for the map-first reset branch. It does not
# add gameplay simulation; it only selects the existing higher-fidelity world
# profile once the main scene is ready.
var _applied := false

func _ready() -> void:
    set_process(true)

func _process(_delta: float) -> void:
    if _applied:
        set_process(false)
        return
    var scene := get_tree().current_scene
    if scene == null:
        return
    if not scene.has_method("set_quality"):
        return

    scene.call("set_quality", "Quality")
    get_viewport().scaling_3d_scale = 1.0

    var environment_value = scene.get("environment")
    if environment_value is Environment:
        var environment: Environment = environment_value
        environment.tonemap_exposure = 1.08
        environment.ambient_light_energy = maxf(environment.ambient_light_energy, 0.78)
        environment.fog_density = minf(environment.fog_density, 0.000018)

    var sun_value = scene.get("sun")
    if sun_value is DirectionalLight3D:
        var sun: DirectionalLight3D = sun_value
        sun.shadow_enabled = true
        sun.directional_shadow_max_distance = maxf(sun.directional_shadow_max_distance, 180.0)

    var buildings_value = scene.get("buildings")
    if buildings_value is JamaicaBuildingStreamer:
        var buildings: JamaicaBuildingStreamer = buildings_value
        buildings.quality = "Quality"
        buildings.draw_distance = maxf(buildings.draw_distance, 1200.0)

    _applied = true
    set_process(false)
