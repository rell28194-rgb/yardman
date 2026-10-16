extends Node
class_name YardmanTrafficPedestrianSafetyRuntime

const STOP_DISTANCE_M := 8.0
const SLOW_DISTANCE_M := 24.0
const LATERAL_CORRIDOR_M := 2.65
const UPDATE_INTERVAL := 0.08

var _clock := 0.0
var _slowing := 0
var _stopped := 0

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS

func _physics_process(delta: float) -> void:
    _clock += delta
    if _clock < UPDATE_INTERVAL:
        return
    _clock = 0.0
    _slowing = 0
    _stopped = 0
    var traffic := get_node_or_null("/root/TrafficRuntime")
    var pedestrians := get_node_or_null("/root/PedestrianRuntime")
    if traffic == null or pedestrians == null:
        return
    var traffic_value = traffic.get("agents")
    var pedestrians_value = pedestrians.get("agents")
    if not traffic_value is Dictionary or not pedestrians_value is Dictionary:
        return
    var traffic_agents: Dictionary = traffic_value
    var pedestrian_agents: Dictionary = pedestrians_value
    if traffic_agents.is_empty() or pedestrian_agents.is_empty():
        return

    var traffic_ids: Array = traffic_agents.keys()
    traffic_ids.sort()
    for identifier_value in traffic_ids:
        var agent: Dictionary = traffic_agents[identifier_value]
        var record: Dictionary = agent.get("record", {})
        var direction := 1 if int(agent.get("direction", 1)) >= 0 else -1
        var pose := YardmanTrafficRuntime.lane_pose(record, float(agent.get("progress", 0.5)), direction)
        if pose.is_empty():
            continue
        var current_speed := maxf(0.0, float(agent.get("speed", 0.0)))
        var cap := pedestrian_speed_cap(Vector2(pose.position), Vector2(pose.travel), pedestrian_agents, float(agent.get("target_speed", current_speed)))
        if cap >= current_speed:
            continue
        # Persist the reduced speed into the traffic agent. The core traffic
        # runtime will start its next acceleration/deceleration step from here.
        # This avoids per-frame ray casts or a second vehicle simulation.
        agent["speed"] = move_toward(current_speed, cap, 3.8)
        if cap <= 0.01:
            _stopped += 1
        else:
            _slowing += 1
        traffic_agents[identifier_value] = agent

static func pedestrian_speed_cap(vehicle_position: Vector2, travel: Vector2, pedestrians: Dictionary, normal_target_speed: float) -> float:
    if travel.length_squared() < 0.5:
        return maxf(0.0, normal_target_speed)
    var forward_axis := travel.normalized()
    var nearest_forward := INF
    for pedestrian_value in pedestrians.values():
        if not pedestrian_value is Dictionary:
            continue
        var pedestrian: Dictionary = pedestrian_value
        var position_value = pedestrian.get("position", null)
        if not position_value is Vector2:
            continue
        var offset: Vector2 = position_value - vehicle_position
        var forward := offset.dot(forward_axis)
        if forward <= 0.0 or forward > SLOW_DISTANCE_M:
            continue
        var lateral := absf(offset.cross(forward_axis))
        if lateral > LATERAL_CORRIDOR_M:
            continue
        nearest_forward = minf(nearest_forward, forward)
    if nearest_forward == INF:
        return maxf(0.0, normal_target_speed)
    if nearest_forward <= STOP_DISTANCE_M:
        return 0.0
    var fraction := clampf((nearest_forward - STOP_DISTANCE_M) / (SLOW_DISTANCE_M - STOP_DISTANCE_M), 0.0, 1.0)
    return minf(maxf(0.0, normal_target_speed), lerpf(2.2, maxf(2.2, normal_target_speed), fraction))

func runtime_snapshot() -> Dictionary:
    return {"slowing_for_pedestrians": _slowing, "stopped_for_pedestrians": _stopped}
