extends Node
class_name YardmanTrafficSignalRuntime

const Traffic = preload("res://scripts/traffic_runtime.gd")
const PlayerSignals = preload("res://scripts/vehicle_signal_runtime.gd")
const UPDATE_INTERVAL := 0.16
const SIGNAL_DISTANCE_M := 34.0

var _clock := 0.0
var _blink_clock := 0.0
var _rigs: Dictionary = {}
var _active_left := 0
var _active_right := 0

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS

func _process(delta: float) -> void:
    _clock += delta
    _blink_clock = fmod(_blink_clock + delta, PlayerSignals.BLINK_PERIOD_S)
    if _clock < UPDATE_INTERVAL:
        _refresh_emission()
        return
    _clock = 0.0
    var scene := get_tree().current_scene
    var traffic := get_node_or_null("/root/TrafficRuntime")
    if scene == null or traffic == null:
        _clear_all()
        return
    var roads = scene.get("roads")
    if roads == null:
        _clear_all()
        return
    var agents_value = traffic.get("agents")
    if not agents_value is Dictionary:
        _clear_all()
        return
    var agents: Dictionary = agents_value
    _prune(agents)
    _active_left = 0
    _active_right = 0
    var identifiers: Array = agents.keys()
    identifiers.sort()
    for identifier_value in identifiers:
        var identifier := str(identifier_value)
        var agent: Dictionary = agents[identifier_value]
        var body_value = agent.get("node", null)
        if not body_value is Node3D or not is_instance_valid(body_value):
            _remove_rig(identifier)
            continue
        var state := desired_signal(agent, roads)
        if state == PlayerSignals.SIGNAL_OFF:
            _remove_rig(identifier)
            continue
        var rig := _ensure_rig(identifier, body_value as Node3D)
        rig["state"] = state
        _rigs[identifier] = rig
        if state == PlayerSignals.SIGNAL_LEFT:
            _active_left += 1
        elif state == PlayerSignals.SIGNAL_RIGHT:
            _active_right += 1
    _refresh_emission()

static func desired_signal(agent: Dictionary, roads) -> String:
    if roads == null:
        return PlayerSignals.SIGNAL_OFF
    var record: Dictionary = agent.get("record", {})
    if record.is_empty():
        return PlayerSignals.SIGNAL_OFF
    var direction := 1 if int(agent.get("direction", 1)) >= 0 else -1
    var progress := clampf(float(agent.get("progress", 0.5)), 0.0, 1.0)
    var pose := Traffic.lane_pose(record, progress, direction)
    if pose.is_empty():
        return PlayerSignals.SIGNAL_OFF
    var endpoint: Vector2 = Vector2(record.get("b", Vector2.ZERO)) if direction >= 0 else Vector2(record.get("a", Vector2.ZERO))
    var remaining := (1.0 - progress) * float(pose.length) if direction >= 0 else progress * float(pose.length)
    if remaining > SIGNAL_DISTANCE_M:
        return PlayerSignals.SIGNAL_OFF
    var candidates_value = roads.call("_nearby_surface_segments", endpoint.x, endpoint.y, 44.0)
    if not candidates_value is Dictionary:
        return PlayerSignals.SIGNAL_OFF
    var continuation := Traffic.continuation_for(record, direction, candidates_value)
    if continuation.is_empty():
        return PlayerSignals.SIGNAL_OFF
    var next_record: Dictionary = continuation.record
    var next_direction := int(continuation.direction)
    var next_pose := Traffic.lane_pose(next_record, 0.05 if next_direction >= 0 else 0.95, next_direction)
    if next_pose.is_empty():
        return PlayerSignals.SIGNAL_OFF
    return turn_state(Vector2(pose.travel), Vector2(next_pose.travel))

static func turn_state(current_travel: Vector2, next_travel: Vector2) -> String:
    if current_travel.length_squared() < 0.5 or next_travel.length_squared() < 0.5:
        return PlayerSignals.SIGNAL_OFF
    var current := current_travel.normalized()
    var next := next_travel.normalized()
    var dot_value := clampf(current.dot(next), -1.0, 1.0)
    var angle := acos(dot_value)
    if angle < deg_to_rad(18.0):
        return PlayerSignals.SIGNAL_OFF
    var cross_value := current.cross(next)
    if absf(cross_value) < 0.08:
        return PlayerSignals.SIGNAL_OFF
    # In Yardman's X/Z road plane, negative cross is a physical left turn.
    return PlayerSignals.SIGNAL_LEFT if cross_value < 0.0 else PlayerSignals.SIGNAL_RIGHT

func _ensure_rig(identifier: String, body: Node3D) -> Dictionary:
    var existing: Dictionary = _rigs.get(identifier, {})
    if not existing.is_empty():
        var root_value = existing.get("root", null)
        if root_value is Node3D and is_instance_valid(root_value) and (root_value as Node3D).get_parent() == body:
            return existing
        _remove_rig(identifier)
    var root := Node3D.new()
    root.name = "TrafficSignalRig"
    body.add_child(root)
    var left := _material()
    var right := _material()
    var positions := PlayerSignals.lamp_positions(Vector3(1.85, 1.30, 4.0))
    _make_lamp(root, "LeftFront", positions.left_front, left)
    _make_lamp(root, "LeftRear", positions.left_rear, left)
    _make_lamp(root, "RightFront", positions.right_front, right)
    _make_lamp(root, "RightRear", positions.right_rear, right)
    return {"root": root, "left": left, "right": right, "state": PlayerSignals.SIGNAL_OFF}

func _material() -> StandardMaterial3D:
    var material := StandardMaterial3D.new()
    material.albedo_color = Color(0.80, 0.25, 0.015)
    material.metallic = 0.10
    material.roughness = 0.24
    material.emission_enabled = true
    material.emission = Color(1.0, 0.33, 0.02)
    material.emission_energy_multiplier = 0.04
    return material

func _make_lamp(root: Node3D, node_name: String, position_value: Vector3, material: StandardMaterial3D) -> void:
    var mesh := BoxMesh.new()
    mesh.size = Vector3(0.15, 0.09, 0.052)
    var instance := MeshInstance3D.new()
    instance.name = node_name
    instance.mesh = mesh
    instance.position = position_value
    instance.material_override = material
    instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    root.add_child(instance)

func _refresh_emission() -> void:
    var flash := PlayerSignals.blink_on(_blink_clock)
    for rig_value in _rigs.values():
        if not rig_value is Dictionary:
            continue
        var rig: Dictionary = rig_value
        var state := str(rig.get("state", PlayerSignals.SIGNAL_OFF))
        var left := rig.get("left", null) as StandardMaterial3D
        var right := rig.get("right", null) as StandardMaterial3D
        if left != null:
            left.emission_energy_multiplier = 2.7 if flash and state == PlayerSignals.SIGNAL_LEFT else 0.04
        if right != null:
            right.emission_energy_multiplier = 2.7 if flash and state == PlayerSignals.SIGNAL_RIGHT else 0.04

func _prune(agents: Dictionary) -> void:
    var stale: Array = []
    for identifier in _rigs.keys():
        if not agents.has(identifier):
            stale.append(identifier)
    for identifier in stale:
        _remove_rig(str(identifier))

func _remove_rig(identifier: String) -> void:
    if not _rigs.has(identifier):
        return
    var rig: Dictionary = _rigs[identifier]
    var root_value = rig.get("root", null)
    if root_value is Node and is_instance_valid(root_value):
        (root_value as Node).queue_free()
    _rigs.erase(identifier)

func _clear_all() -> void:
    var identifiers: Array = _rigs.keys()
    for identifier in identifiers:
        _remove_rig(str(identifier))
    _active_left = 0
    _active_right = 0

func runtime_snapshot() -> Dictionary:
    return {
        "signal_rigs": _rigs.size(),
        "left": _active_left,
        "right": _active_right,
    }
