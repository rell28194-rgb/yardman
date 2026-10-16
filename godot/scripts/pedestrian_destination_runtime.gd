extends Node
class_name YardmanPedestrianDestinationRuntime

const UPDATE_INTERVAL := 0.20
const ARRIVAL_PROGRESS := 0.025

var _plans: Dictionary = {}
var _clock := 0.0
var _moving := 0
var _dwelling := 0
var _completed := 0

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS

func _physics_process(delta: float) -> void:
    _clock += delta
    if _clock < UPDATE_INTERVAL:
        return
    var step := _clock
    _clock = 0.0
    var pedestrians := get_node_or_null("/root/PedestrianRuntime")
    if pedestrians == null:
        _plans.clear()
        _moving = 0
        _dwelling = 0
        return
    var agents_value = pedestrians.get("agents")
    if not agents_value is Dictionary:
        return
    var agents: Dictionary = agents_value
    _prune(agents)
    _moving = 0
    _dwelling = 0
    var identifiers: Array = agents.keys()
    identifiers.sort()
    for identifier_value in identifiers:
        var identifier := str(identifier_value)
        var agent: Dictionary = agents[identifier_value]
        var record: Dictionary = agent.get("record", {})
        var edge_id := str(record.get("edge_id", ""))
        if edge_id.is_empty():
            continue
        var direction := 1 if int(agent.get("direction", 1)) >= 0 else -1
        var progress := clampf(float(agent.get("progress", 0.5)), 0.0, 1.0)
        var base_speed := maxf(0.72, float(agent.get("base_speed", agent.get("speed", 1.15))))
        agent["base_speed"] = base_speed
        var plan: Dictionary = _plans.get(identifier, {})
        if plan.is_empty() or str(plan.get("edge_id", "")) != edge_id or int(plan.get("direction", direction)) != direction:
            plan = make_plan(identifier, edge_id, direction, progress, int(plan.get("sequence", 0)))

        var dwell_remaining := maxf(0.0, float(plan.get("dwell_remaining", 0.0)))
        if dwell_remaining > 0.0:
            dwell_remaining = maxf(0.0, dwell_remaining - step)
            plan["dwell_remaining"] = dwell_remaining
            agent["speed"] = 0.0
            agent["activity_state"] = "dwelling"
            agent["destination_progress"] = float(plan.destination_progress)
            _dwelling += 1
            if dwell_remaining <= 0.0:
                var sequence := int(plan.get("sequence", 0)) + 1
                plan = make_plan(identifier, edge_id, direction, progress, sequence)
                agent["speed"] = base_speed
                agent["activity_state"] = "walking"
            _plans[identifier] = plan
            agents[identifier_value] = agent
            continue

        if reached_destination(progress, float(plan.destination_progress), direction):
            plan["dwell_remaining"] = dwell_seconds(identifier, int(plan.get("sequence", 0)))
            agent["speed"] = 0.0
            agent["activity_state"] = "dwelling"
            agent["destination_progress"] = float(plan.destination_progress)
            _dwelling += 1
            _completed += 1
        else:
            agent["speed"] = base_speed
            agent["activity_state"] = "walking"
            agent["destination_progress"] = float(plan.destination_progress)
            _moving += 1
        _plans[identifier] = plan
        agents[identifier_value] = agent

func _prune(agents: Dictionary) -> void:
    var stale: Array = []
    for identifier in _plans.keys():
        if not agents.has(identifier):
            stale.append(identifier)
    for identifier in stale:
        _plans.erase(identifier)

static func make_plan(identifier: String, edge_id: String, direction: int, progress: float, sequence: int) -> Dictionary:
    var travel_direction := 1 if direction >= 0 else -1
    var seed := deterministic_seed(identifier, edge_id, sequence)
    var distance_fraction := 0.14 + float(seed % 3300) / 10000.0
    var target := progress + float(travel_direction) * distance_fraction
    # Objectives may extend just beyond a segment seam. In that case the core
    # road-continuation system changes edge first, which invalidates this plan
    # and generates a new objective on the actual connected road. This avoids
    # inventing pedestrian crossings or teleporting between corridors.
    target = clampf(target, -0.08, 1.08)
    return {
        "edge_id": edge_id,
        "direction": travel_direction,
        "destination_progress": target,
        "dwell_remaining": 0.0,
        "sequence": sequence,
    }

static func deterministic_seed(identifier: String, edge_id: String, sequence: int) -> int:
    var value: int = int((identifier + "|" + edge_id + "|" + str(sequence) + "|yardman-ped-dest-v1").hash())
    if value == -9223372036854775808:
        return 0
    return absi(value)

static func dwell_seconds(identifier: String, sequence: int) -> float:
    var seed := deterministic_seed(identifier, "dwell", sequence)
    return 2.5 + float(seed % 7500) / 1000.0

static func reached_destination(progress: float, destination: float, direction: int) -> bool:
    if absf(progress - destination) <= ARRIVAL_PROGRESS:
        return true
    if direction >= 0:
        return progress > destination
    return progress < destination

func runtime_snapshot() -> Dictionary:
    return {
        "plans": _plans.size(),
        "moving": _moving,
        "dwelling": _dwelling,
        "completed_objectives": _completed,
    }
