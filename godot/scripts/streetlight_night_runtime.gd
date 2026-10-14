extends Node
class_name YardmanStreetlightNightRuntime

const MAX_CANDIDATE_SCAN := 640
const FIXTURE_LIGHT_HEIGHT_M := 8.55
const LIGHT_RANGE_M := 23.0
const LIGHT_ENERGY := 2.35

var max_real_lights := 8
var renderer := "mobile"
var quality := "Balanced"
var thermal_stage := 0
var _pool: Array[OmniLight3D] = []
var _pool_root: Node3D
var _scene: Node
var _refresh_clock := 0.0
var _active_count := 0
var _candidate_count := 0
var _last_night_factor := 0.0

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    add_to_group("yardman_render_quality")

func _process(delta: float) -> void:
    _refresh_clock += delta
    if _refresh_clock < 0.40:
        return
    _refresh_clock = 0.0
    var scene := get_tree().current_scene
    if scene == null:
        _release_scene()
        return
    if _scene != scene or _pool_root == null or not is_instance_valid(_pool_root):
        _attach_scene(scene)
    var hour := float(scene.get("day_hour"))
    var night := night_factor(hour)
    _last_night_factor = night
    if night <= 0.001:
        _candidate_count = 0
        _set_active_lights([], night)
        return

    var active_position := _active_position(scene)
    if active_position == null:
        _set_active_lights([], night)
        return
    var candidates := _streetlight_candidates(scene)
    _candidate_count = candidates.size()
    var selected := nearest_positions(candidates, active_position, max_real_lights)
    _set_active_lights(selected, night)

func apply_render_policy(active: Dictionary) -> void:
    renderer = str(active.get("renderer", renderer))
    quality = str(active.get("quality", quality))
    thermal_stage = clampi(int(active.get("thermal_stage", thermal_stage)), 0, 5)
    var budget := budget_for(quality, thermal_stage, renderer)
    max_real_lights = int(budget.real_lights)
    _ensure_pool(max_real_lights)

static func budget_for(quality_name: String, stage_value: int, renderer_name: String = "mobile") -> Dictionary:
    var base := 8
    match quality_name:
        "Performance":
            base = 4
        "Quality":
            base = 12
        "Ultra":
            base = 16
        "Custom":
            base = 8
    if renderer_name == "gl_compatibility":
        base = mini(base, 7)
    var stage := clampi(stage_value, 0, 5)
    var factor: float = float([1.0, 1.0, 0.88, 0.72, 0.56, 0.42][stage])
    return {"real_lights": maxi(2, int(round(float(base) * factor))), "thermal_stage": stage}

static func night_factor(hour: float) -> float:
    var h := fmod(hour + 24.0, 24.0)
    if h >= 19.0 or h < 5.25:
        return 1.0
    if h >= 5.25 and h < 6.5:
        return 1.0 - smoothstep(5.25, 6.5, h)
    if h >= 18.0 and h < 19.0:
        return smoothstep(18.0, 19.0, h)
    return 0.0

static func nearest_positions(candidates: Array, origin: Vector3, limit: int) -> Array:
    var ranked: Array = []
    for candidate_value in candidates:
        if not candidate_value is Vector3:
            continue
        var candidate := candidate_value as Vector3
        if not candidate.is_finite():
            continue
        ranked.append({"position": candidate, "distance2": origin.distance_squared_to(candidate)})
    ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        if is_equal_approx(float(a.distance2), float(b.distance2)):
            var ap: Vector3 = a.position
            var bp: Vector3 = b.position
            if not is_equal_approx(ap.x, bp.x):
                return ap.x < bp.x
            if not is_equal_approx(ap.z, bp.z):
                return ap.z < bp.z
            return ap.y < bp.y
        return float(a.distance2) < float(b.distance2))
    var result: Array = []
    var count := mini(maxi(limit, 0), ranked.size())
    for index in range(count):
        result.append(ranked[index].position)
    return result

func _active_position(scene: Node):
    var player = scene.get("player")
    var car = scene.get("car")
    if player is Node3D and car is Node3D:
        return (car as Node3D).global_position if bool(player.get("in_vehicle")) else (player as Node3D).global_position
    if car is Node3D:
        return (car as Node3D).global_position
    if player is Node3D:
        return (player as Node3D).global_position
    return null

func _streetlight_candidates(scene: Node) -> Array:
    var terrain = scene.get("terrain")
    if terrain == null:
        terrain = scene.get_node_or_null("JamaicaTerrainStreamer")
    if terrain == null:
        return []
    var loaded = terrain.get("_loaded")
    if not loaded is Dictionary:
        return []
    var result: Array = []
    for tile_root_value in loaded.values():
        if not tile_root_value is Node3D:
            continue
        var tile_root := tile_root_value as Node3D
        var instance := tile_root.get_node_or_null("StreetLightProxy/StreetLightFallback") as MultiMeshInstance3D
        if instance == null or instance.multimesh == null:
            continue
        var count := mini(instance.multimesh.instance_count, MAX_CANDIDATE_SCAN - result.size())
        for index in range(count):
            var transform := instance.multimesh.get_instance_transform(index)
            result.append(instance.to_global(transform.origin + Vector3.UP * FIXTURE_LIGHT_HEIGHT_M))
        if result.size() >= MAX_CANDIDATE_SCAN:
            break
    return result

func _attach_scene(scene: Node) -> void:
    _release_scene()
    _scene = scene
    _pool_root = Node3D.new()
    _pool_root.name = "NightStreetLightPool"
    _pool_root.set_meta("placement_authority", "existing OSM highway=street_lamp MultiMesh transforms only")
    scene.add_child(_pool_root)
    _ensure_pool(max_real_lights)

func _ensure_pool(required: int) -> void:
    if _pool_root == null or not is_instance_valid(_pool_root):
        return
    var wanted := maxi(required, 2)
    while _pool.size() < wanted:
        var light := OmniLight3D.new()
        light.name = "StreetLampLight%02d" % _pool.size()
        light.light_color = Color(1.0, 0.76, 0.48)
        light.light_energy = 0.0
        light.omni_range = LIGHT_RANGE_M
        light.omni_attenuation = 1.35
        light.shadow_enabled = false
        light.distance_fade_enabled = true
        light.distance_fade_begin = 120.0
        light.distance_fade_length = 70.0
        light.visible = false
        _pool_root.add_child(light)
        _pool.append(light)
    for index in range(_pool.size()):
        if index >= wanted:
            _pool[index].visible = false
            _pool[index].light_energy = 0.0

func _set_active_lights(positions: Array, night: float) -> void:
    _ensure_pool(max_real_lights)
    var count := mini(positions.size(), max_real_lights)
    for index in range(_pool.size()):
        var light := _pool[index]
        var active := index < count and index < max_real_lights
        light.visible = active and night > 0.001
        light.light_energy = LIGHT_ENERGY * night if active else 0.0
        if active:
            light.global_position = positions[index]
    _active_count = count if night > 0.001 else 0

func _release_scene() -> void:
    if _pool_root != null and is_instance_valid(_pool_root):
        _pool_root.queue_free()
    _pool.clear()
    _pool_root = null
    _scene = null
    _active_count = 0
    _candidate_count = 0

func runtime_snapshot() -> Dictionary:
    return {
        "active_lights": _active_count,
        "candidate_lamps": _candidate_count,
        "night_factor": _last_night_factor,
        "light_budget": max_real_lights,
        "renderer": renderer,
        "quality": quality,
        "thermal_stage": thermal_stage,
    }
