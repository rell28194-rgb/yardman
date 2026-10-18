extends Node
class_name YardmanTrafficRuntime

const VehicleModelScript = preload("res://scripts/vehicle_model.gd")
const ROAD_FLAG_ONEWAY := 1
const ROAD_FLAG_ONEWAY_REVERSE := 16

var max_agents := 18
var near_visual_budget := 6
var near_radius := 190.0
var medium_radius := 460.0
var spawn_radius := 440.0
var despawn_radius := 540.0
var agents: Dictionary = {}
var _spawn_clock := 0.0
var _proxy: MultiMeshInstance3D
var _proxy_scene: Node
var _last_near := 0
var _last_medium := 0
var _far_statistical := 0
var _last_yielding := 0
var _quality := "Balanced"
var _thermal_stage := 0
var _weather_speed_factor := 1.0
var _weather_density_factor := 1.0

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    add_to_group("yardman_render_quality")

func _physics_process(delta: float) -> void:
    var scene := get_tree().current_scene
    if scene == null:
        _clear_scene_state()
        return
    var roads = scene.get("roads")
    var terrain = scene.get("terrain")
    var player = scene.get("player")
    var car = scene.get("car")
    if roads == null or terrain == null or player == null or car == null:
        return
    _ensure_proxy(scene)
    var active: Node3D = car if bool(player.get("in_vehicle")) else player
    var active_world: PackedFloat64Array = roads.local_to_world(active.global_position)
    var active_xz := Vector2(float(active_world[0]), float(active_world[2]))

    _update_weather_factors()
    _spawn_clock += delta
    if _spawn_clock >= 1.0:
        _spawn_clock = 0.0
        _reconcile_population(scene, roads, terrain, active_xz)
    _advance_agents(delta, roads, terrain, active_xz)
    _refresh_visuals(scene, roads, terrain, active_xz)

func apply_render_policy(active: Dictionary) -> void:
    _quality = str(active.get("quality", "Balanced"))
    _thermal_stage = clampi(int(active.get("thermal_stage", 0)), 0, 5)
    var budget := budget_for(_quality, _thermal_stage)
    max_agents = int(budget.max_agents)
    near_visual_budget = int(budget.near_visuals)
    near_radius = float(budget.near_radius)
    medium_radius = float(budget.medium_radius)
    spawn_radius = minf(500.0, medium_radius - 10.0)
    despawn_radius = minf(512.0, medium_radius + 52.0)
    if _proxy != null and _proxy.multimesh != null and _proxy.multimesh.instance_count != max_agents:
        _proxy.multimesh.instance_count = max_agents
        _proxy.multimesh.visible_instance_count = 0

static func budget_for(quality: String, thermal_stage: int) -> Dictionary:
    var base_agents := 18
    var near := 6
    var near_distance := 190.0
    var medium_distance := 460.0
    match quality:
        "Performance":
            base_agents = 12
            near = 4
            near_distance = 155.0
            medium_distance = 380.0
        "Quality":
            base_agents = 22
            near = 8
            near_distance = 225.0
            medium_distance = 490.0
        "Ultra":
            base_agents = 26
            near = 10
            near_distance = 255.0
            medium_distance = 510.0
    var stage := clampi(thermal_stage, 0, 5)
    var factor: float = float([1.0, 0.95, 0.88, 0.74, 0.62, 0.52][stage])
    return {
        "max_agents": maxi(8, int(round(float(base_agents) * factor))),
        "near_visuals": maxi(3, int(round(float(near) * factor))),
        "near_radius": maxf(120.0, near_distance * lerpf(0.78, 1.0, factor)),
        "medium_radius": maxf(320.0, medium_distance * lerpf(0.78, 1.0, factor)),
    }

static func density_for_hour(hour: float) -> float:
    var h := fmod(hour + 24.0, 24.0)
    if h < 5.0:
        return 0.46
    if h < 7.0:
        return lerpf(0.46, 0.92, (h - 5.0) / 2.0)
    if h < 9.5:
        return 1.0
    if h < 15.5:
        return 0.78
    if h < 19.0:
        return 0.96
    if h < 22.0:
        return 0.72
    return 0.54

static func weather_speed_factor(rain_intensity: float, standing_water: float) -> float:
    var rain := clampf(rain_intensity, 0.0, 1.0)
    var water := clampf(standing_water, 0.0, 1.0)
    return clampf(1.0 - rain * 0.18 - water * 0.14, 0.64, 1.0)

static func weather_density_factor(rain_intensity: float) -> float:
    return clampf(1.0 - clampf(rain_intensity, 0.0, 1.0) * 0.16, 0.78, 1.0)

static func statistical_population_for(capacity: int, hour: float, weather_factor: float) -> int:
    var island_scale := float(maxi(capacity, 8)) * 3.4
    return maxi(0, int(round(island_scale * density_for_hour(hour) * clampf(weather_factor, 0.70, 1.0))))

static func legal_direction_for(record: Dictionary, fallback_direction: int) -> int:
    var fallback := 1 if fallback_direction >= 0 else -1
    var flags := int(record.get("flags", 0))
    if (flags & ROAD_FLAG_ONEWAY) == 0:
        return fallback
    return -1 if (flags & ROAD_FLAG_ONEWAY_REVERSE) != 0 else 1

static func lane_pose(record: Dictionary, progress: float, direction_sign: int) -> Dictionary:
    var a: Vector2 = record.get("a", Vector2.ZERO)
    var b: Vector2 = record.get("b", Vector2.ZERO)
    var tangent := b - a
    var length := tangent.length()
    if length < 0.001:
        return {}
    tangent /= length
    var direction := 1 if direction_sign >= 0 else -1
    var travel := tangent * float(direction)
    var t := clampf(progress, 0.0, 1.0)
    var center := a.lerp(b, t)
    # Jamaica drives on the left. Offset to the left of the current travel
    # direction while staying inside the source carriageway width.
    var left := Vector2(travel.y, -travel.x)
    var width := maxf(3.0, float(record.get("width_m", 6.5)))
    var lane_offset := minf(width * 0.23, maxf(1.15, width * 0.34))
    var point := center + left * lane_offset
    return {
        "position": point,
        "travel": travel,
        "heading": atan2(-travel.x, -travel.y),
        "length": length,
    }

static func road_deck_height(record: Dictionary, progress: float, terrain_height: float) -> float:
    var height_a_value = record.get("height_a", null)
    var height_b_value = record.get("height_b", null)
    if height_a_value != null and height_b_value != null:
        var height_a := float(height_a_value)
        var height_b := float(height_b_value)
        if is_finite(height_a) and is_finite(height_b):
            return lerpf(height_a, height_b, clampf(progress, 0.0, 1.0))
    return terrain_height

static func continuation_for(current: Dictionary, direction_sign: int, candidates: Dictionary) -> Dictionary:
    var a: Vector2 = current.get("a", Vector2.ZERO)
    var b: Vector2 = current.get("b", Vector2.ZERO)
    var endpoint := b if direction_sign >= 0 else a
    var tangent := (b - a).normalized() * float(1 if direction_sign >= 0 else -1)
    var current_id := str(current.get("edge_id", ""))
    var best: Dictionary = {}
    var best_score := -INF
    var keys: Array = candidates.keys()
    keys.sort()
    for key in keys:
        var candidate: Dictionary = candidates[key]
        if str(candidate.get("edge_id", key)) == current_id:
            continue
        var ca: Vector2 = candidate.get("a", Vector2.ZERO)
        var cb: Vector2 = candidate.get("b", Vector2.ZERO)
        var candidate_direction := 0
        var start := Vector2.ZERO
        var travel := Vector2.ZERO
        var da := endpoint.distance_to(ca)
        var db := endpoint.distance_to(cb)
        var distance := minf(da, db)
        if distance > 18.0:
            continue
        if da <= db:
            candidate_direction = 1
            start = ca
            travel = (cb - ca).normalized()
        else:
            candidate_direction = -1
            start = cb
            travel = (ca - cb).normalized()
        if legal_direction_for(candidate, candidate_direction) != candidate_direction:
            continue
        if travel.length_squared() < 0.5:
            continue
        var alignment := tangent.dot(travel)
        if alignment < -0.25:
            continue
        var score := alignment * 5.0 - distance * 0.18 - float(absi(str(key).hash()) % 29) * 0.0001
        if score > best_score:
            best_score = score
            best = {"record": candidate, "direction": candidate_direction, "join": start, "score": score}
    return best

static func junction_options(current: Dictionary, direction_sign: int, candidates: Dictionary) -> Array[Dictionary]:
    var a: Vector2 = current.get("a", Vector2.ZERO)
    var b: Vector2 = current.get("b", Vector2.ZERO)
    var endpoint: Vector2 = b if direction_sign >= 0 else a
    var tangent := (b - a).normalized() * float(1 if direction_sign >= 0 else -1)
    var current_id := str(current.get("edge_id", ""))
    var options: Array[Dictionary] = []
    var keys: Array = candidates.keys()
    keys.sort()
    for key in keys:
        var candidate: Dictionary = candidates[key]
        if str(candidate.get("edge_id", key)) == current_id:
            continue
        var ca: Vector2 = candidate.get("a", Vector2.ZERO)
        var cb: Vector2 = candidate.get("b", Vector2.ZERO)
        var da := endpoint.distance_to(ca)
        var db := endpoint.distance_to(cb)
        var distance := minf(da, db)
        if distance > 18.0:
            continue
        var candidate_direction := 1 if da <= db else -1
        if legal_direction_for(candidate, candidate_direction) != candidate_direction:
            continue
        var travel := (cb - ca).normalized() if candidate_direction >= 0 else (ca - cb).normalized()
        if travel.length_squared() < 0.5:
            continue
        var alignment := tangent.dot(travel)
        if alignment < -0.25:
            continue
        options.append({
            "record": candidate,
            "direction": candidate_direction,
            "distance": distance,
            "alignment": alignment,
            "edge_id": str(candidate.get("edge_id", key)),
        })
    return options

static func road_priority(record: Dictionary) -> float:
    var class_id := clampi(int(record.get("class_id", 5)), 0, 15)
    var width := clampf(float(record.get("width_m", 6.5)), 3.0, 20.0)
    return 100.0 - float(class_id) * 8.0 + width * 0.35

static func should_yield_at_junction(identifier: String, current: Dictionary, direction_sign: int,
        endpoint: Vector2, population: Dictionary, radius_m: float = 18.0) -> bool:
    var a: Vector2 = current.get("a", Vector2.ZERO)
    var b: Vector2 = current.get("b", Vector2.ZERO)
    var my_travel := (b - a).normalized() * float(1 if direction_sign >= 0 else -1)
    if my_travel.length_squared() < 0.5:
        return false
    var my_priority := road_priority(current)
    var ids: Array = population.keys()
    ids.sort()
    for other_id_value in ids:
        var other_id := str(other_id_value)
        if other_id == identifier:
            continue
        var other: Dictionary = population[other_id_value]
        var other_point: Vector2 = other.get("position", Vector2.ZERO)
        var distance := other_point.distance_to(endpoint)
        if distance > radius_m:
            continue
        var other_record: Dictionary = other.get("record", {})
        var other_direction := int(other.get("direction", 1))
        var other_pose := lane_pose(other_record, float(other.get("progress", 0.5)), other_direction)
        if other_pose.is_empty():
            continue
        var other_travel: Vector2 = other_pose.travel
        if other_travel.dot(my_travel) > 0.92:
            continue
        if distance > 0.5:
            var toward_junction := (endpoint - other_point) / distance
            if other_travel.dot(toward_junction) < 0.18:
                continue
        var other_priority := road_priority(other_record)
        if other_priority > my_priority + 0.05:
            return true
        if is_equal_approx(other_priority, my_priority) and other_id < identifier:
            return true
    return false

func _update_weather_factors() -> void:
    var rain := 0.0
    var standing_water := 0.0
    var atmosphere := get_node_or_null("/root/AtmosphereFX")
    if atmosphere != null and atmosphere.has_method("weather_snapshot"):
        var snapshot = atmosphere.call("weather_snapshot")
        if snapshot is Dictionary:
            rain = float(snapshot.get("rain_intensity", 0.0))
            standing_water = float(snapshot.get("standing_water", 0.0))
    _weather_speed_factor = weather_speed_factor(rain, standing_water)
    _weather_density_factor = weather_density_factor(rain)

func _reconcile_population(scene: Node, roads, terrain, active_xz: Vector2) -> void:
    var records_value = roads.call("_nearby_surface_segments", active_xz.x, active_xz.y, minf(spawn_radius, 500.0))
    if not records_value is Dictionary:
        return
    var records: Dictionary = records_value
    var hour := float(scene.get("day_hour"))
    var density := density_for_hour(hour) * _weather_density_factor
    var target := clampi(int(round(float(max_agents) * density)), 4, max_agents)
    var far_target := statistical_population_for(max_agents, hour, _weather_density_factor)

    for identifier in agents.keys():
        var agent: Dictionary = agents[identifier]
        var point: Vector2 = agent.get("position", Vector2.ZERO)
        if point.distance_to(active_xz) > despawn_radius:
            _destroy_agent(str(identifier))

    # Density and thermal changes must retire existing simulation work as well
    # as limit new spawns. Keep the closest actors to avoid nearby pop-out.
    _trim_population(target, active_xz)
    if agents.size() >= target:
        _far_statistical = maxi(0, far_target - agents.size())
        return

    var keys: Array = records.keys()
    keys.sort()
    for key in keys:
        if agents.size() >= target:
            break
        var record: Dictionary = records[key]
        if (int(record.get("flags", 0)) & 8) != 0:
            continue
        var segment_length := (Vector2(record.get("b", Vector2.ZERO)) - Vector2(record.get("a", Vector2.ZERO))).length()
        if segment_length < 18.0:
            continue
        var edge_id := str(record.get("edge_id", key))
        var fallback_direction := 1 if (absi(edge_id.hash()) & 1) == 0 else -1
        var direction := legal_direction_for(record, fallback_direction)
        var identifier := "%s:%d" % [edge_id, direction]
        if agents.has(identifier):
            continue
        var seed := absi(identifier.hash())
        var progress := 0.12 + float(seed % 7300) / 10000.0
        var pose := lane_pose(record, progress, direction)
        if pose.is_empty():
            continue
        var point: Vector2 = pose.position
        if point.distance_to(active_xz) < 42.0:
            continue
        var speed_limit_value = record.get("speed_limit_mps", null)
        var target_speed := float(speed_limit_value) if speed_limit_value != null else _default_speed(int(record.get("class_id", 0)))
        target_speed = clampf(target_speed * (0.82 + float(seed % 13) * 0.012), 6.0, 24.0)
        agents[identifier] = {
            "id": identifier,
            "record": record.duplicate(true),
            "direction": direction,
            "progress": progress,
            "position": point,
            "heading": float(pose.heading),
            "speed": target_speed * 0.72 * _weather_speed_factor,
            "target_speed": target_speed,
            "node": null,
            "model": null,
        }
    _far_statistical = maxi(0, far_target - agents.size())

func _default_speed(class_id: int) -> float:
    if class_id <= 1:
        return 18.0
    if class_id <= 3:
        return 14.0
    return 10.5

func _advance_agents(delta: float, roads, terrain, active_xz: Vector2) -> void:
    _last_yielding = 0
    var ids: Array = agents.keys()
    ids.sort()
    for identifier in ids:
        if not agents.has(identifier):
            continue
        var agent: Dictionary = agents[identifier]
        var record: Dictionary = agent.record
        var direction := int(agent.direction)
        var pose := lane_pose(record, float(agent.progress), direction)
        if pose.is_empty():
            _destroy_agent(str(identifier))
            continue
        var point: Vector2 = pose.position
        var target_speed := float(agent.target_speed) * _weather_speed_factor
        var player_distance := point.distance_to(active_xz)
        if player_distance < 9.0:
            target_speed = 0.0
        elif player_distance < 18.0:
            target_speed *= 0.35
        var nearest_ahead := _nearest_agent_distance(str(identifier), point, Vector2(pose.travel))
        if nearest_ahead < 7.0:
            target_speed = 0.0
        elif nearest_ahead < 16.0:
            target_speed *= clampf((nearest_ahead - 6.0) / 10.0, 0.12, 1.0)

        var endpoint := Vector2(record.b if direction >= 0 else record.a)
        var endpoint_fraction := 1.0 - float(agent.progress) if direction >= 0 else float(agent.progress)
        var endpoint_distance := maxf(0.0, endpoint_fraction * float(pose.length))
        var junction_candidates: Dictionary = {}
        if endpoint_distance <= 22.0:
            var nearby_value = roads.call("_nearby_surface_segments", endpoint.x, endpoint.y, 44.0)
            if nearby_value is Dictionary:
                junction_candidates = nearby_value
                var options := junction_options(record, direction, junction_candidates)
                if options.size() > 1:
                    var approach_scale := clampf(endpoint_distance / 22.0, 0.28, 1.0)
                    target_speed = minf(target_speed, maxf(3.2, float(agent.target_speed) * _weather_speed_factor * approach_scale))
                    if endpoint_distance <= 16.0 and should_yield_at_junction(str(identifier), record, direction, endpoint, agents):
                        target_speed = 0.0
                        _last_yielding += 1

        var speed := move_toward(float(agent.speed), target_speed, delta * (4.6 if target_speed < float(agent.speed) else 2.2))
        var progress := float(agent.progress) + float(direction) * speed * delta / maxf(float(pose.length), 0.1)
        if progress > 1.0 or progress < 0.0:
            if junction_candidates.is_empty():
                var candidates_value = roads.call("_nearby_surface_segments", endpoint.x, endpoint.y, 44.0)
                if candidates_value is Dictionary:
                    junction_candidates = candidates_value
            var continuation := continuation_for(record, direction, junction_candidates)
            if continuation.is_empty():
                _destroy_agent(str(identifier))
                continue
            record = continuation.record
            direction = int(continuation.direction)
            progress = 0.015 if direction >= 0 else 0.985
            pose = lane_pose(record, progress, direction)
            if pose.is_empty():
                _destroy_agent(str(identifier))
                continue
        point = Vector2(pose.position)
        agent.record = record
        agent.direction = direction
        agent.progress = progress
        agent.position = point
        agent.heading = float(pose.heading)
        agent.speed = speed
        agents[identifier] = agent

func _nearest_agent_distance(identifier: String, point: Vector2, travel: Vector2) -> float:
    var nearest := INF
    for other_id in agents.keys():
        if str(other_id) == identifier:
            continue
        var other: Dictionary = agents[other_id]
        var offset: Vector2 = Vector2(other.get("position", Vector2.ZERO)) - point
        if offset.dot(travel) <= 0.0:
            continue
        var forward := offset.dot(travel)
        var lateral := absf(offset.cross(travel))
        if lateral < 3.2:
            nearest = minf(nearest, forward)
    return nearest

func _visual_priority_ids(active_xz: Vector2) -> Array:
    var ids: Array = agents.keys()
    ids.sort_custom(func(a, b):
        var distance_a := Vector2(agents[a].position).distance_squared_to(active_xz)
        var distance_b := Vector2(agents[b].position).distance_squared_to(active_xz)
        if distance_a == distance_b:
            return str(a) < str(b)
        return distance_a < distance_b
    )
    return ids

func _refresh_visuals(scene: Node, roads, terrain, active_xz: Vector2) -> void:
    if _proxy == null or _proxy.multimesh == null:
        return
    var near_count := 0
    var proxy_count := 0
    var ids := _visual_priority_ids(active_xz)
    for identifier in ids:
        var agent: Dictionary = agents[identifier]
        var point: Vector2 = agent.position
        var distance := point.distance_to(active_xz)
        var terrain_y := float(terrain.height_at(point.x, point.y))
        var deck_y := road_deck_height(agent.record, float(agent.progress), terrain_y)
        if not is_finite(deck_y):
            _dematerialize_agent(str(identifier))
            continue
        var local: Vector3 = roads.world_to_local(point.x, point.y, deck_y + 0.46)
        if distance <= near_radius and near_count < near_visual_budget:
            _materialize_agent(scene, str(identifier), agent)
            agent = agents[identifier]
            var node := agent.node as AnimatableBody3D
            if node != null:
                node.position = local
                node.rotation.y = float(agent.heading)
                var model := agent.model as YardmanVehicleModel
                if model != null:
                    model.update_motion(get_physics_process_delta_time(), float(agent.speed), 0.0, 0.0, false, true, 0.0, 0.0)
            near_count += 1
        else:
            _dematerialize_agent(str(identifier))
            if distance <= medium_radius and proxy_count < _proxy.multimesh.instance_count:
                var basis := Basis(Vector3.UP, float(agent.heading))
                _proxy.multimesh.set_instance_transform(proxy_count, Transform3D(basis, local + Vector3.UP * 0.18))
                proxy_count += 1
    _proxy.multimesh.visible_instance_count = proxy_count
    _last_near = near_count
    _last_medium = proxy_count

func _materialize_agent(scene: Node, identifier: String, agent: Dictionary) -> void:
    if agent.get("node", null) is AnimatableBody3D and is_instance_valid(agent.node):
        return
    var body := AnimatableBody3D.new()
    body.name = "Traffic_" + identifier.replace(":", "_").replace("/", "_")
    body.collision_layer = 1
    body.collision_mask = 0
    body.sync_to_physics = true
    var shape := BoxShape3D.new()
    shape.size = Vector3(1.85, 1.30, 4.0)
    var collider := CollisionShape3D.new()
    collider.shape = shape
    collider.position.y = 0.65
    body.add_child(collider)
    var model := VehicleModelScript.new()
    model.name = "TrafficVisual"
    model.build()
    body.add_child(model)
    scene.add_child(body)
    agent.node = body
    agent.model = model
    agents[identifier] = agent

func _dematerialize_agent(identifier: String) -> void:
    if not agents.has(identifier):
        return
    var agent: Dictionary = agents[identifier]
    var node = agent.get("node", null)
    if node is Node and is_instance_valid(node):
        (node as Node).queue_free()
    agent.node = null
    agent.model = null
    agents[identifier] = agent

func _trim_population(target: int, active_xz: Vector2) -> void:
    if agents.size() <= target:
        return
    var ids: Array = agents.keys()
    ids.sort_custom(func(a, b):
        var distance_a := Vector2(agents[a].position).distance_squared_to(active_xz)
        var distance_b := Vector2(agents[b].position).distance_squared_to(active_xz)
        if distance_a == distance_b:
            return str(a) < str(b)
        return distance_a < distance_b
    )
    for index in range(maxi(0, target), ids.size()):
        _destroy_agent(str(ids[index]))

func _destroy_agent(identifier: String) -> void:
    if not agents.has(identifier):
        return
    _dematerialize_agent(identifier)
    agents.erase(identifier)

func _ensure_proxy(scene: Node) -> void:
    if _proxy != null and is_instance_valid(_proxy) and _proxy_scene == scene:
        return
    if _proxy != null and is_instance_valid(_proxy):
        _proxy.queue_free()
    _proxy_scene = scene
    _proxy = MultiMeshInstance3D.new()
    _proxy.name = "TrafficMediumHLOD"
    _proxy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    var mesh := BoxMesh.new()
    mesh.size = Vector3(1.78, 1.22, 3.85)
    var material := StandardMaterial3D.new()
    material.albedo_color = Color(0.16, 0.18, 0.20)
    material.roughness = 0.56
    mesh.material = material
    var multimesh := MultiMesh.new()
    multimesh.transform_format = MultiMesh.TRANSFORM_3D
    multimesh.mesh = mesh
    multimesh.instance_count = max_agents
    multimesh.visible_instance_count = 0
    _proxy.multimesh = multimesh
    scene.add_child(_proxy)

func _clear_scene_state() -> void:
    for identifier in agents.keys():
        _dematerialize_agent(str(identifier))
    agents.clear()
    if _proxy != null and is_instance_valid(_proxy):
        _proxy.queue_free()
    _proxy = null
    _proxy_scene = null
    _last_near = 0
    _last_medium = 0
    _far_statistical = 0
    _last_yielding = 0
    _weather_speed_factor = 1.0
    _weather_density_factor = 1.0

func runtime_snapshot() -> Dictionary:
    return {
        "agents": agents.size(),
        "near_full": _last_near,
        "medium_hlod": _last_medium,
        "far_statistical": _far_statistical,
        "yielding": _last_yielding,
        "quality": _quality,
        "thermal_stage": _thermal_stage,
        "near_budget": near_visual_budget,
        "weather_speed_factor": _weather_speed_factor,
        "weather_density_factor": _weather_density_factor,
    }