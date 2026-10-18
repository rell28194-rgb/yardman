extends Node
class_name YardmanPedestrianRuntime

const TrafficScript = preload("res://scripts/traffic_runtime.gd")

var max_agents := 18
var near_visual_budget := 7
var near_radius := 90.0
var medium_radius := 260.0
var spawn_radius := 300.0
var despawn_radius := 360.0
var agents: Dictionary = {}
var _spawn_clock := 0.0
var _proxy: MultiMeshInstance3D
var _proxy_scene: Node
var _last_near := 0
var _last_medium := 0
var _far_statistical := 0
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
    if _spawn_clock >= 1.25:
        _spawn_clock = 0.0
        _reconcile_population(scene, roads, active_xz)
    _advance_agents(delta, roads, active_xz)
    _refresh_visuals(scene, roads, terrain, active_xz, delta)

func apply_render_policy(active: Dictionary) -> void:
    _quality = str(active.get("quality", "Balanced"))
    _thermal_stage = clampi(int(active.get("thermal_stage", 0)), 0, 5)
    var budget := budget_for(_quality, _thermal_stage)
    max_agents = int(budget.max_agents)
    near_visual_budget = int(budget.near_visuals)
    near_radius = float(budget.near_radius)
    medium_radius = float(budget.medium_radius)
    spawn_radius = minf(360.0, medium_radius + 35.0)
    despawn_radius = minf(430.0, medium_radius + 95.0)
    if _proxy != null and _proxy.multimesh != null and _proxy.multimesh.instance_count != max_agents:
        _proxy.multimesh.visible_instance_count = 0
        _proxy.multimesh.instance_count = max_agents

static func budget_for(quality: String, thermal_stage: int) -> Dictionary:
    var count := 18
    var near := 7
    var near_distance := 90.0
    var medium_distance := 260.0
    match quality:
        "Performance":
            count = 11
            near = 4
            near_distance = 72.0
            medium_distance = 205.0
        "Quality":
            count = 24
            near = 10
            near_distance = 110.0
            medium_distance = 305.0
        "Ultra":
            count = 30
            near = 12
            near_distance = 130.0
            medium_distance = 340.0
    var stage := clampi(thermal_stage, 0, 5)
    var factor: float = float([1.0, 0.95, 0.87, 0.74, 0.61, 0.50][stage])
    return {
        "max_agents": maxi(7, int(round(float(count) * factor))),
        "near_visuals": maxi(3, int(round(float(near) * factor))),
        "near_radius": maxf(60.0, near_distance * lerpf(0.80, 1.0, factor)),
        "medium_radius": maxf(175.0, medium_distance * lerpf(0.78, 1.0, factor)),
    }

static func density_for_hour(hour: float) -> float:
    var h := fmod(hour + 24.0, 24.0)
    if h < 5.0:
        return 0.22
    if h < 7.0:
        return lerpf(0.22, 0.72, (h - 5.0) / 2.0)
    if h < 10.0:
        return 0.82
    if h < 16.0:
        return 1.0
    if h < 20.0:
        return 0.92
    if h < 23.0:
        return 0.58
    return 0.32

static func weather_walk_speed_factor(rain_intensity: float, standing_water: float) -> float:
    var rain := clampf(rain_intensity, 0.0, 1.0)
    var water := clampf(standing_water, 0.0, 1.0)
    return clampf(1.0 - rain * 0.12 - water * 0.10, 0.72, 1.0)

static func weather_density_factor(rain_intensity: float) -> float:
    return clampf(1.0 - clampf(rain_intensity, 0.0, 1.0) * 0.34, 0.62, 1.0)

static func statistical_population_for(capacity: int, hour: float, weather_factor: float) -> int:
    var island_scale := float(maxi(capacity, 7)) * 4.2
    return maxi(0, int(round(island_scale * density_for_hour(hour) * clampf(weather_factor, 0.55, 1.0))))

static func roadside_walk_pose(record: Dictionary, progress: float, direction_sign: int, side_sign: int) -> Dictionary:
    # Roadside corridors are inferred context, not mapped sidewalks. Never extend
    # them through bridges or tunnels, where doing so would fabricate support.
    if (int(record.get("flags", 0)) & 6) != 0:
        return {}
    var a: Vector2 = record.get("a", Vector2.ZERO)
    var b: Vector2 = record.get("b", Vector2.ZERO)
    var tangent := b - a
    var length := tangent.length()
    if length < 0.001:
        return {}
    tangent /= length
    var direction := 1 if direction_sign >= 0 else -1
    var travel := tangent * float(direction)
    var normal := Vector2(-tangent.y, tangent.x) * float(1 if side_sign >= 0 else -1)
    var width := maxf(3.0, float(record.get("width_m", 6.0)))
    # Until registered sidewalk data exists, keep pedestrians outside the real
    # carriageway on a reversible road-context walking corridor.
    var offset := width * 0.5 + 1.65
    var point := a.lerp(b, clampf(progress, 0.0, 1.0)) + normal * offset
    return {
        "position": point,
        "travel": travel,
        "heading": atan2(-travel.x, -travel.y),
        "length": length,
        "offset": offset,
    }

func _update_weather_factors() -> void:
    var rain := 0.0
    var standing_water := 0.0
    var atmosphere := get_node_or_null("/root/AtmosphereFX")
    if atmosphere != null and atmosphere.has_method("weather_snapshot"):
        var snapshot = atmosphere.call("weather_snapshot")
        if snapshot is Dictionary:
            rain = float(snapshot.get("rain_intensity", 0.0))
            standing_water = float(snapshot.get("standing_water", 0.0))
    _weather_speed_factor = weather_walk_speed_factor(rain, standing_water)
    _weather_density_factor = weather_density_factor(rain)

func _reconcile_population(scene: Node, roads, active_xz: Vector2) -> void:
    var records_value = roads.call("_nearby_surface_segments", active_xz.x, active_xz.y, minf(spawn_radius, 360.0))
    if not records_value is Dictionary:
        return
    var records: Dictionary = records_value
    var hour := float(scene.get("day_hour"))
    var target := clampi(int(round(float(max_agents) * density_for_hour(hour) * _weather_density_factor)), 3, max_agents)
    var far_target := statistical_population_for(max_agents, hour, _weather_density_factor)

    for identifier in agents.keys():
        var agent: Dictionary = agents[identifier]
        if Vector2(agent.position).distance_to(active_xz) > despawn_radius:
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
        var edge_id := str(record.get("edge_id", key))
        var seed := absi(edge_id.hash())
        if seed % 3 == 2:
            continue
        var direction := 1 if ((seed >> 2) & 1) == 0 else -1
        var side := 1 if ((seed >> 4) & 1) == 0 else -1
        var identifier := "%s:ped:%d:%d" % [edge_id, direction, side]
        if agents.has(identifier):
            continue
        var progress := 0.10 + float((seed >> 6) % 7900) / 10000.0
        var pose := roadside_walk_pose(record, progress, direction, side)
        if pose.is_empty():
            continue
        var point: Vector2 = pose.position
        if point.distance_to(active_xz) < 18.0:
            continue
        var base_speed := 1.05 + float(seed % 35) * 0.012
        agents[identifier] = {
            "id": identifier,
            "record": record.duplicate(true),
            "direction": direction,
            "side": side,
            "progress": progress,
            "position": point,
            "heading": float(pose.heading),
            "speed": base_speed,
            "node": null,
            "rig": {},
            "gait": float(seed % 628) / 100.0,
        }
    _far_statistical = maxi(0, far_target - agents.size())

func _advance_agents(delta: float, roads, active_xz: Vector2) -> void:
    var ids: Array = agents.keys()
    ids.sort()
    for identifier in ids:
        if not agents.has(identifier):
            continue
        var agent: Dictionary = agents[identifier]
        var record: Dictionary = agent.record
        var direction := int(agent.direction)
        var side := int(agent.side)
        var pose := roadside_walk_pose(record, float(agent.progress), direction, side)
        if pose.is_empty():
            _destroy_agent(str(identifier))
            continue
        var point: Vector2 = pose.position
        var speed := float(agent.speed) * _weather_speed_factor
        var distance_to_player := point.distance_to(active_xz)
        if distance_to_player < 2.4:
            speed = 0.0
        elif distance_to_player < 4.5:
            speed *= 0.35
        var progress := float(agent.progress) + float(direction) * speed * delta / maxf(float(pose.length), 0.1)
        if progress > 1.0 or progress < 0.0:
            var candidates_value = roads.call("_nearby_surface_segments", Vector2(record.b if direction >= 0 else record.a).x, Vector2(record.b if direction >= 0 else record.a).y, 35.0)
            var continuation := TrafficScript.continuation_for(record, direction, candidates_value if candidates_value is Dictionary else {})
            if continuation.is_empty():
                direction = -direction
                progress = 0.985 if direction < 0 else 0.015
            else:
                record = continuation.record
                direction = int(continuation.direction)
                progress = 0.015 if direction >= 0 else 0.985
            pose = roadside_walk_pose(record, progress, direction, side)
            if pose.is_empty():
                _destroy_agent(str(identifier))
                continue
        point = Vector2(pose.position)
        agent.record = record
        agent.direction = direction
        agent.progress = progress
        agent.position = point
        agent.heading = float(pose.heading)
        agent.gait = fmod(float(agent.gait) + delta * (5.0 + speed * 1.8), TAU)
        agents[identifier] = agent

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

func _refresh_visuals(scene: Node, roads, terrain, active_xz: Vector2, delta: float) -> void:
    if _proxy == null or _proxy.multimesh == null:
        return
    var near_count := 0
    var proxy_count := 0
    var ids := _visual_priority_ids(active_xz)
    for identifier in ids:
        var agent: Dictionary = agents[identifier]
        var point: Vector2 = agent.position
        var distance := point.distance_to(active_xz)
        var ground_y := float(terrain.height_at(point.x, point.y)) + 0.04
        var local: Vector3 = roads.world_to_local(point.x, point.y, ground_y)
        if distance <= near_radius and near_count < near_visual_budget:
            _materialize_agent(scene, str(identifier), agent)
            agent = agents[identifier]
            var node := agent.node as AnimatableBody3D
            if node != null:
                node.position = local
                node.rotation.y = float(agent.heading)
                _animate_rig(agent, delta)
            near_count += 1
        else:
            _dematerialize_agent(str(identifier))
            if distance <= medium_radius and proxy_count < _proxy.multimesh.instance_count:
                _proxy.multimesh.set_instance_transform(proxy_count, Transform3D(Basis(Vector3.UP, float(agent.heading)), local + Vector3.UP * 0.88))
                proxy_count += 1
    _proxy.multimesh.visible_instance_count = proxy_count
    _last_near = near_count
    _last_medium = proxy_count

func _materialize_agent(scene: Node, identifier: String, agent: Dictionary) -> void:
    if agent.get("node", null) is AnimatableBody3D and is_instance_valid(agent.node):
        return
    var body := AnimatableBody3D.new()
    body.name = "Pedestrian_" + identifier.replace(":", "_").replace("/", "_")
    body.collision_layer = 1
    body.collision_mask = 0
    body.sync_to_physics = true
    var capsule := CapsuleShape3D.new()
    capsule.radius = 0.27
    capsule.height = 1.72
    var collider := CollisionShape3D.new()
    collider.shape = capsule
    collider.position.y = 0.86
    body.add_child(collider)
    var rig := _build_rig(absi(identifier.hash()))
    body.add_child(rig.root)
    scene.add_child(body)
    agent.node = body
    agent.rig = rig
    agents[identifier] = agent

func _build_rig(seed: int) -> Dictionary:
    var root := Node3D.new()
    root.name = "PedestrianRig"
    var skin := Color(0.25 + float(seed % 7) * 0.045, 0.14 + float(seed % 5) * 0.028, 0.09 + float(seed % 3) * 0.022)
    var shirt := Color(0.18 + float((seed >> 3) % 5) * 0.11, 0.20 + float((seed >> 5) % 4) * 0.10, 0.22 + float((seed >> 7) % 4) * 0.09)
    var trousers := Color(0.09, 0.11, 0.14).lerp(Color(0.24, 0.22, 0.18), float(seed % 4) / 5.0)
    _part(root, _capsule_mesh(0.22, 0.62), Vector3(0, 1.13, 0), shirt)
    var head := SphereMesh.new()
    head.radius = 0.16
    head.height = 0.32
    head.radial_segments = 10
    head.rings = 5
    _part(root, head, Vector3(0, 1.62, 0), skin)
    var left_leg := _limb(root, Vector3(-0.11, 0.82, 0), 0.082, 0.72, trousers)
    var right_leg := _limb(root, Vector3(0.11, 0.82, 0), 0.082, 0.72, trousers)
    var left_arm := _limb(root, Vector3(-0.28, 1.38, 0), 0.066, 0.56, skin)
    var right_arm := _limb(root, Vector3(0.28, 1.38, 0), 0.066, 0.56, skin)
    return {"root": root, "left_leg": left_leg, "right_leg": right_leg, "left_arm": left_arm, "right_arm": right_arm}

func _animate_rig(agent: Dictionary, delta: float) -> void:
    var rig: Dictionary = agent.get("rig", {})
    if rig.is_empty():
        return
    var phase := float(agent.gait)
    var swing := sin(phase) * 0.42
    var left_leg := rig.get("left_leg") as Node3D
    var right_leg := rig.get("right_leg") as Node3D
    var left_arm := rig.get("left_arm") as Node3D
    var right_arm := rig.get("right_arm") as Node3D
    if left_leg != null:
        left_leg.rotation.x = lerpf(left_leg.rotation.x, swing, clampf(delta * 12.0, 0.0, 1.0))
    if right_leg != null:
        right_leg.rotation.x = lerpf(right_leg.rotation.x, -swing, clampf(delta * 12.0, 0.0, 1.0))
    if left_arm != null:
        left_arm.rotation.x = lerpf(left_arm.rotation.x, -swing * 0.75, clampf(delta * 12.0, 0.0, 1.0))
    if right_arm != null:
        right_arm.rotation.x = lerpf(right_arm.rotation.x, swing * 0.75, clampf(delta * 12.0, 0.0, 1.0))

func _part(parent: Node3D, mesh: Mesh, position_local: Vector3, color: Color) -> MeshInstance3D:
    var instance := MeshInstance3D.new()
    instance.mesh = mesh
    instance.position = position_local
    var material := StandardMaterial3D.new()
    material.albedo_color = color
    material.roughness = 0.84
    instance.material_override = material
    parent.add_child(instance)
    return instance

func _capsule_mesh(radius: float, height: float) -> CapsuleMesh:
    var mesh := CapsuleMesh.new()
    mesh.radius = radius
    mesh.height = height
    mesh.radial_segments = 8
    mesh.rings = 3
    return mesh

func _limb(parent: Node3D, origin: Vector3, radius: float, length: float, color: Color) -> Node3D:
    var pivot := Node3D.new()
    pivot.position = origin
    parent.add_child(pivot)
    _part(pivot, _capsule_mesh(radius, length), Vector3(0, -length * 0.45, 0), color)
    return pivot

func _dematerialize_agent(identifier: String) -> void:
    if not agents.has(identifier):
        return
    var agent: Dictionary = agents[identifier]
    var node = agent.get("node", null)
    if node is Node and is_instance_valid(node):
        (node as Node).queue_free()
    agent.node = null
    agent.rig = {}
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
    _proxy.name = "PedestrianMediumHLOD"
    _proxy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    var mesh := CapsuleMesh.new()
    mesh.radius = 0.24
    mesh.height = 1.70
    mesh.radial_segments = 6
    mesh.rings = 2
    var material := StandardMaterial3D.new()
    material.albedo_color = Color(0.22, 0.25, 0.24)
    material.roughness = 0.88
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
    _weather_speed_factor = 1.0
    _weather_density_factor = 1.0

func runtime_snapshot() -> Dictionary:
    return {
        "agents": agents.size(),
        "near_full": _last_near,
        "medium_hlod": _last_medium,
        "far_statistical": _far_statistical,
        "quality": _quality,
        "thermal_stage": _thermal_stage,
        "weather_speed_factor": _weather_speed_factor,
        "weather_density_factor": _weather_density_factor,
    }