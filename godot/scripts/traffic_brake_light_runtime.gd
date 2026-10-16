extends Node
class_name YardmanTrafficBrakeLightRuntime

const UPDATE_INTERVAL := 0.08
const STOPPED_SPEED_MPS := 0.75
const DECELERATION_STEP_MPS := 0.22
const BRAKE_ENERGY := 2.0
const RUNNING_ENERGY := 0.35

var _clock := 0.0
var _previous_speed: Dictionary = {}
var _braking_count := 0

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS

func _process(delta: float) -> void:
    _clock += delta
    if _clock < UPDATE_INTERVAL:
        return
    _clock = 0.0
    _braking_count = 0
    var traffic := get_node_or_null("/root/TrafficRuntime")
    if traffic == null:
        _previous_speed.clear()
        return
    var agents_value = traffic.get("agents")
    if not agents_value is Dictionary:
        return
    var agents: Dictionary = agents_value
    var live: Dictionary = {}
    for identifier_value in agents.keys():
        var identifier := str(identifier_value)
        var agent: Dictionary = agents[identifier_value]
        var current_speed := maxf(0.0, float(agent.get("speed", 0.0)))
        var previous := float(_previous_speed.get(identifier, current_speed))
        var active := brake_active(previous, current_speed)
        _previous_speed[identifier] = current_speed
        live[identifier] = true
        var model_value = agent.get("model", null)
        if model_value is Node3D and is_instance_valid(model_value):
            _set_model_brake(model_value as Node3D, active)
            if active:
                _braking_count += 1
    var stale: Array = []
    for identifier in _previous_speed.keys():
        if not live.has(identifier):
            stale.append(identifier)
    for identifier in stale:
        _previous_speed.erase(identifier)

static func brake_active(previous_speed: float, current_speed: float) -> bool:
    var previous := maxf(0.0, previous_speed)
    var current := maxf(0.0, current_speed)
    return current <= STOPPED_SPEED_MPS or current <= previous - DECELERATION_STEP_MPS

static func emission_energy(active: bool) -> float:
    return BRAKE_ENERGY if active else RUNNING_ENERGY

func _set_model_brake(model: Node3D, active: bool) -> void:
    var energy := emission_energy(active)
    var primary = model.get("brake_material")
    if primary is StandardMaterial3D:
        (primary as StandardMaterial3D).emission_energy_multiplier = energy
    var materials_value = model.get("_brake_materials")
    if materials_value is Array:
        for material_value in materials_value:
            if material_value is StandardMaterial3D:
                (material_value as StandardMaterial3D).emission_energy_multiplier = energy

func runtime_snapshot() -> Dictionary:
    return {"tracked_agents": _previous_speed.size(), "braking_materialized": _braking_count}
