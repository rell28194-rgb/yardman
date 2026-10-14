extends Node
class_name YardmanTrafficHeadlightRuntime

const PlayerHeadlights = preload("res://scripts/vehicle_headlight_runtime.gd")

var renderer := "mobile"
var quality := "Balanced"
var thermal_stage := 0
var max_headlit_vehicles := 2
var _pool: Array[SpotLight3D] = []
var _root: Node3D
var _scene: Node
var _refresh_clock := 0.0
var _active_count := 0
var _last_factor := 0.0

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    add_to_group("yardman_render_quality")

func _process(delta: float) -> void:
    _refresh_clock += delta
    if _refresh_clock < 0.12:
        return
    _refresh_clock = 0.0
    var scene := get_tree().current_scene
    if scene == null:
        _release_scene()
        return
    if _scene != scene or _root == null or not is_instance_valid(_root):
        _attach_scene(scene)
    var traffic := get_node_or_null("/root/TrafficRuntime")
    if traffic == null:
        _disable_pool()
        return
    var agents_value = traffic.get("agents")
    if not agents_value is Dictionary:
        _disable_pool()
        return
    var player = scene.get("player")
    var car = scene.get("car")
    var active: Node3D
    if player is Node3D and car is Node3D:
        active = car as Node3D if bool(player.get("in_vehicle")) else player as Node3D
    elif car is Node3D:
        active = car as Node3D
    elif player is Node3D:
        active = player as Node3D
    else:
        _disable_pool()
        return
    var rain := 0.0
    var atmosphere := get_node_or_null("/root/AtmosphereFX")
    if atmosphere != null:
        rain = clampf(float(atmosphere.get("rain_intensity")), 0.0, 1.0)
    var factor := PlayerHeadlights.activation_for(float(scene.get("day_hour")), rain)
    _last_factor = factor
    if factor <= 0.015:
        _disable_pool()
        return
    var candidates: Array = []
    var agents: Dictionary = agents_value
    var identifiers: Array = agents.keys()
    identifiers.sort()
    for identifier in identifiers:
        var agent: Dictionary = agents[identifier]
        var node = agent.get("node", null)
        if not node is Node3D or not is_instance_valid(node):
            continue
        var body := node as Node3D
        candidates.append({"id": str(identifier), "position": body.global_position, "node": body})
    var selected := select_nearest(candidates, active.global_position, max_headlit_vehicles)
    var budget := budget_for(quality, thermal_stage, renderer)
    _active_count = apply_selected_lights(selected, _pool, factor, budget)

func apply_render_policy(active: Dictionary) -> void:
    renderer = str(active.get("renderer", renderer))
    quality = str(active.get("quality", quality))
    thermal_stage = clampi(int(active.get("thermal_stage", thermal_stage)), 0, 5)
    var budget := budget_for(quality, thermal_stage, renderer)
    max_headlit_vehicles = int(budget.vehicles)
    _ensure_pool(max_headlit_vehicles)

static func budget_for(quality_name: String, stage_value: int, renderer_name: String = "mobile") -> Dictionary:
    var vehicles := 2
    var energy := 2.6
    var range_m := 31.0
    match quality_name:
        "Performance":
            vehicles = 1
            energy = 2.2
            range_m = 26.0
        "Quality":
            vehicles = 3
            energy = 2.8
            range_m = 34.0
        "Ultra":
            vehicles = 4
            energy = 3.0
            range_m = 37.0
    if renderer_name == "gl_compatibility" or renderer_name == "gles":
        vehicles = mini(vehicles, 2)
        energy = minf(energy, 2.4)
        range_m = minf(range_m, 29.0)
    var stage := clampi(stage_value, 0, 5)
    var factors: Array[float] = [1.0, 1.0, 0.90, 0.76, 0.62, 0.50]
    var factor: float = factors[stage]
    vehicles = maxi(1, int(round(float(vehicles) * factor)))
    return {
        "vehicles": vehicles,
        "energy": maxf(1.8, energy * lerpf(0.78, 1.0, factor)),
        "range_m": maxf(22.0, range_m * lerpf(0.76, 1.0, factor)),
        "thermal_stage": stage,
    }

static func select_nearest(candidates: Array, origin: Vector3, limit: int) -> Array:
    var ranked: Array = []
    for candidate_value in candidates:
        if not candidate_value is Dictionary:
            continue
        var candidate: Dictionary = candidate_value
        var position_value = candidate.get("position", null)
        if not position_value is Vector3:
            continue
        var position: Vector3 = position_value
        if not position.is_finite():
            continue
        var entry := candidate.duplicate()
        entry["distance2"] = origin.distance_squared_to(position)
        ranked.append(entry)
    ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        if is_equal_approx(float(a.distance2), float(b.distance2)):
            return str(a.get("id", "")) < str(b.get("id", ""))
        return float(a.distance2) < float(b.distance2))
    var count := mini(maxi(limit, 0), ranked.size())
    var result: Array = []
    for index in range(count):
        result.append(ranked[index])
    return result

static func apply_selected_lights(selected: Array, pool: Array, factor: float, budget: Dictionary) -> int:
    var level := clampf(factor, 0.0, 1.0)
    var count := mini(selected.size(), pool.size()) if level > 0.015 else 0
    for index in range(pool.size()):
        var value = pool[index]
        if not value is SpotLight3D:
            continue
        var light := value as SpotLight3D
        var enabled := index < count
        light.visible = enabled
        light.light_energy = float(budget.get("energy", 2.6)) * level if enabled else 0.0
        light.spot_range = float(budget.get("range_m", 31.0))
        light.spot_angle = 34.0
        light.shadow_enabled = false
        if enabled:
            var entry: Dictionary = selected[index]
            var node = entry.get("node", null)
            if node is Node3D and is_instance_valid(node):
                var body := node as Node3D
                light.global_transform = body.global_transform * Transform3D(Basis.IDENTITY, Vector3(0.0, 0.69, -2.05))
            elif entry.get("position", null) is Vector3:
                light.global_position = entry.position
    return count

func _attach_scene(scene: Node) -> void:
    _release_scene()
    _scene = scene
    _root = Node3D.new()
    _root.name = "TrafficHeadlightPool"
    scene.add_child(_root)
    _ensure_pool(max_headlit_vehicles)

func _ensure_pool(required: int) -> void:
    if _root == null or not is_instance_valid(_root):
        return
    var wanted := maxi(required, 1)
    while _pool.size() < wanted:
        var light := SpotLight3D.new()
        light.name = "TrafficHeadlight%02d" % _pool.size()
        light.light_color = Color(1.0, 0.89, 0.72)
        light.light_energy = 0.0
        light.spot_range = 31.0
        light.spot_angle = 34.0
        light.spot_angle_attenuation = 1.25
        light.shadow_enabled = false
        light.distance_fade_enabled = true
        light.distance_fade_begin = 22.0
        light.distance_fade_length = 18.0
        light.visible = false
        _root.add_child(light)
        _pool.append(light)
    for index in range(_pool.size()):
        if index >= wanted:
            _pool[index].visible = false
            _pool[index].light_energy = 0.0

func _disable_pool() -> void:
    for light in _pool:
        light.visible = false
        light.light_energy = 0.0
    _active_count = 0

func _release_scene() -> void:
    if _root != null and is_instance_valid(_root):
        _root.queue_free()
    _pool.clear()
    _root = null
    _scene = null
    _active_count = 0

func runtime_snapshot() -> Dictionary:
    return {
        "active_vehicle_lights": _active_count,
        "vehicle_budget": max_headlit_vehicles,
        "activation": _last_factor,
        "renderer": renderer,
        "quality": quality,
        "thermal_stage": thermal_stage,
    }
