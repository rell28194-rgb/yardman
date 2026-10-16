extends Node
class_name YardmanParkedVehicleRuntime

const VehicleModelScript = preload("res://scripts/vehicle_model.gd")

var max_parked := 10
var near_visual_budget := 4
var near_radius := 155.0
var medium_radius := 430.0
var parked: Dictionary = {}
var _refresh_clock := 0.0
var _visual_clock := 0.0
const VISUAL_INTERVAL := 0.12
var _proxy: MultiMeshInstance3D
var _proxy_scene: Node
var _parked_pool: Array[StaticBody3D] = []
var _last_near := 0
var _last_medium := 0
var _quality := "Balanced"
var _thermal_stage := 0

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    add_to_group("yardman_render_quality")

func _process(delta: float) -> void:
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
    _refresh_clock += delta
    _visual_clock += delta
    if _refresh_clock >= 2.0:
        _refresh_clock = 0.0
        _reconcile(roads, active_xz)
        _visual_clock = VISUAL_INTERVAL
    if _visual_clock >= VISUAL_INTERVAL:
        _visual_clock = 0.0
        _refresh_visuals(scene, roads, terrain, active_xz)

func apply_render_policy(active: Dictionary) -> void:
    _quality = str(active.get("quality", "Balanced"))
    _thermal_stage = clampi(int(active.get("thermal_stage", 0)), 0, 5)
    var budget := budget_for(_quality, _thermal_stage)
    max_parked = int(budget.max_parked)
    near_visual_budget = int(budget.near_visuals)
    near_radius = float(budget.near_radius)
    medium_radius = float(budget.medium_radius)
    if _proxy != null and _proxy.multimesh != null and _proxy.multimesh.instance_count != max_parked:
        _proxy.multimesh.visible_instance_count = 0
        _proxy.multimesh.instance_count = max_parked

static func budget_for(quality: String, thermal_stage: int) -> Dictionary:
    var count := 10
    var near := 4
    var near_distance := 155.0
    var medium_distance := 430.0
    match quality:
        "Performance":
            count = 7
            near = 3
            near_distance = 130.0
            medium_distance = 340.0
        "Quality":
            count = 14
            near = 6
            near_distance = 190.0
            medium_distance = 470.0
        "Ultra":
            count = 18
            near = 7
            near_distance = 220.0
            medium_distance = 500.0
    var stage := clampi(thermal_stage, 0, 5)
    var factor: float = float([1.0, 0.96, 0.88, 0.78, 0.66, 0.56][stage])
    return {"max_parked": maxi(4, int(round(float(count) * factor))), "near_visuals": maxi(2, int(round(float(near) * factor))), "near_radius": maxf(105.0, near_distance * lerpf(0.82, 1.0, factor)), "medium_radius": maxf(290.0, medium_distance * lerpf(0.80, 1.0, factor))}

static func parked_pose(record: Dictionary, progress: float, side_sign: int) -> Dictionary:
    var a: Vector2 = record.get("a", Vector2.ZERO)
    var b: Vector2 = record.get("b", Vector2.ZERO)
    var tangent := b - a
    var length := tangent.length()
    if length < 0.001:
        return {}
    tangent /= length
    var t := clampf(progress, 0.08, 0.92)
    var center := a.lerp(b, t)
    var normal := Vector2(-tangent.y, tangent.x) * float(1 if side_sign >= 0 else -1)
    var width := maxf(3.0, float(record.get("width_m", 6.5)))
    var shoulder_offset := width * 0.5 + 1.12
    return {"position": center + normal * shoulder_offset, "heading": atan2(-tangent.x, -tangent.y) + (0.0 if side_sign >= 0 else PI), "shoulder_offset": shoulder_offset, "length": length, "progress": t}

static func _compiled_deck_height(record: Dictionary, progress: float) -> float:
    var a_value = record.get("height_a", null)
    var b_value = record.get("height_b", null)
    if a_value == null or b_value == null:
        return NAN
    var a := float(a_value)
    var b := float(b_value)
    if not is_finite(a) or not is_finite(b):
        return NAN
    return lerpf(a, b, clampf(progress, 0.0, 1.0))

func _reconcile(roads, active_xz: Vector2) -> void:
    var records_value = roads.call("_nearby_surface_segments", active_xz.x, active_xz.y, minf(medium_radius, 500.0))
    if not records_value is Dictionary:
        return
    var records: Dictionary = records_value
    for identifier in parked.keys():
        var entry: Dictionary = parked[identifier]
        if Vector2(entry.position).distance_to(active_xz) > minf(512.0, medium_radius + 65.0):
            _destroy(str(identifier))
    if parked.size() >= max_parked:
        return
    var keys: Array = records.keys()
    keys.sort()
    for key in keys:
        if parked.size() >= max_parked:
            break
        var record: Dictionary = records[key]
        if (int(record.get("flags", 0)) & 8) != 0 or float(record.get("width_m", 0.0)) < 6.2:
            continue
        var edge_id := str(record.get("edge_id", key))
        var seed := absi(edge_id.hash())
        if seed % 4 != 0:
            continue
        var side := 1 if ((seed >> 3) & 1) == 0 else -1
        var progress := 0.18 + float((seed >> 5) % 6200) / 10000.0
        var identifier := "%s:parked:%d" % [edge_id, side]
        if parked.has(identifier):
            continue
        var pose := parked_pose(record, progress, side)
        if pose.is_empty():
            continue
        var point: Vector2 = pose.position
        if point.distance_to(active_xz) < 32.0:
            continue
        parked[identifier] = {"record": record.duplicate(true), "progress": float(pose.progress), "position": point, "heading": float(pose.heading), "node": null, "model": null}

func _refresh_visuals(scene: Node, roads, terrain, active_xz: Vector2) -> void:
    if _proxy == null or _proxy.multimesh == null:
        return
    var near_count := 0
    var proxy_count := 0
    var ids: Array = parked.keys()
    ids.sort()
    for identifier in ids:
        var entry: Dictionary = parked[identifier]
        var point: Vector2 = entry.position
        var distance := point.distance_to(active_xz)
        var deck_y := _compiled_deck_height(entry.record, float(entry.get("progress", 0.5)))
        if not is_finite(deck_y):
            deck_y = float(terrain.height_at(point.x, point.y))
        if not is_finite(deck_y):
            _dematerialize(str(identifier))
            continue
        var local: Vector3 = roads.world_to_local(point.x, point.y, deck_y + 0.46)
        if distance <= near_radius and near_count < near_visual_budget:
            _materialize(scene, str(identifier), entry)
            entry = parked[identifier]
            var node := entry.node as StaticBody3D
            if node != null:
                node.position = local
                node.rotation.y = float(entry.heading)
            near_count += 1
        else:
            _dematerialize(str(identifier))
            if distance <= medium_radius and proxy_count < _proxy.multimesh.instance_count:
                _proxy.multimesh.set_instance_transform(proxy_count, Transform3D(Basis(Vector3.UP, float(entry.heading)), local + Vector3.UP * 0.18))
                proxy_count += 1
    _proxy.multimesh.visible_instance_count = proxy_count
    _last_near = near_count
    _last_medium = proxy_count

func _materialize(scene: Node, identifier: String, entry: Dictionary) -> void:
    if entry.get("node", null) is StaticBody3D and is_instance_valid(entry.node):
        return
    var body: StaticBody3D
    while not _parked_pool.is_empty() and body == null:
        var candidate := _parked_pool.pop_back()
        if is_instance_valid(candidate):
            body = candidate
    if body == null:
        body = _create_parked_body()
        scene.add_child(body)
    elif body.get_parent() != scene:
        if body.get_parent() != null:
            body.get_parent().remove_child(body)
        scene.add_child(body)
    body.name = "Parked_" + identifier.replace(":", "_").replace("/", "_")
    body.visible = true
    body.process_mode = Node.PROCESS_MODE_INHERIT
    body.collision_layer = 1
    var collider := body.get_node_or_null("CollisionShape3D") as CollisionShape3D
    if collider != null:
        collider.set_deferred("disabled", false)
    entry.node = body
    entry.model = body.get_node_or_null("ParkedVisual")
    parked[identifier] = entry

func _create_parked_body() -> StaticBody3D:
    var body := StaticBody3D.new()
    body.collision_layer = 0
    body.collision_mask = 0
    var shape := BoxShape3D.new()
    shape.size = Vector3(1.85, 1.30, 4.0)
    var collider := CollisionShape3D.new()
    collider.name = "CollisionShape3D"
    collider.shape = shape
    collider.position.y = 0.65
    body.add_child(collider)
    var model := VehicleModelScript.new()
    model.name = "ParkedVisual"
    model.build()
    body.add_child(model)
    return body

func _dematerialize(identifier: String) -> void:
    if not parked.has(identifier):
        return
    var entry: Dictionary = parked[identifier]
    var node = entry.get("node", null)
    if node is StaticBody3D and is_instance_valid(node):
        var body := node as StaticBody3D
        body.visible = false
        body.process_mode = Node.PROCESS_MODE_DISABLED
        body.collision_layer = 0
        var collider := body.get_node_or_null("CollisionShape3D") as CollisionShape3D
        if collider != null:
            collider.set_deferred("disabled", true)
        _parked_pool.append(body)
    entry.node = null
    entry.model = null
    parked[identifier] = entry

func _destroy(identifier: String) -> void:
    if not parked.has(identifier):
        return
    _dematerialize(identifier)
    parked.erase(identifier)

func _ensure_proxy(scene: Node) -> void:
    if _proxy != null and is_instance_valid(_proxy) and _proxy_scene == scene:
        return
    if _proxy != null and is_instance_valid(_proxy):
        _proxy.queue_free()
    _clear_pool()
    _proxy_scene = scene
    _proxy = MultiMeshInstance3D.new()
    _proxy.name = "ParkedVehicleMediumHLOD"
    _proxy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    var mesh := BoxMesh.new()
    mesh.size = Vector3(1.78, 1.22, 3.85)
    var material := StandardMaterial3D.new()
    material.albedo_color = Color(0.23, 0.24, 0.25)
    material.roughness = 0.62
    mesh.material = material
    var multimesh := MultiMesh.new()
    multimesh.transform_format = MultiMesh.TRANSFORM_3D
    multimesh.mesh = mesh
    multimesh.instance_count = max_parked
    multimesh.visible_instance_count = 0
    _proxy.multimesh = multimesh
    scene.add_child(_proxy)

func _clear_pool() -> void:
    for body in _parked_pool:
        if is_instance_valid(body):
            body.queue_free()
    _parked_pool.clear()

func _clear_scene_state() -> void:
    for identifier in parked.keys():
        _dematerialize(str(identifier))
    parked.clear()
    _clear_pool()
    if _proxy != null and is_instance_valid(_proxy):
        _proxy.queue_free()
    _proxy = null
    _proxy_scene = null
    _last_near = 0
    _last_medium = 0

func runtime_snapshot() -> Dictionary:
    return {"parked": parked.size(), "near_full": _last_near, "medium_hlod": _last_medium, "pooled_near": _parked_pool.size(), "quality": _quality, "thermal_stage": _thermal_stage}
