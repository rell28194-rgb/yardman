extends Node
class_name YardmanPedestrianIdleRuntime

const UPDATE_INTERVAL := 0.10
var _idle_clock := 0.0
var _update_clock := 0.0
var _overrides := 0
var _pedestrians: Node

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS

func _physics_process(delta: float) -> void:
    _update_clock += delta
    if _update_clock < UPDATE_INTERVAL:
        return
    var step := _update_clock
    _update_clock = 0.0
    _idle_clock += step
    _overrides = 0
    if _pedestrians == null or not is_instance_valid(_pedestrians):
        _pedestrians = get_node_or_null("/root/PedestrianRuntime")
    if _pedestrians == null:
        return
    var agents_value = _pedestrians.get("agents")
    if not agents_value is Dictionary:
        return
    var agents: Dictionary = agents_value
    for identifier_value in agents.keys():
        var agent: Dictionary = agents[identifier_value]
        if str(agent.get("activity_state", "walking")) != "dwelling":
            continue
        var node_value = agent.get("node", null)
        if not node_value is AnimatableBody3D or not is_instance_valid(node_value):
            continue
        var rig_value = agent.get("rig", {})
        if not rig_value is Dictionary or rig_value.is_empty():
            continue
        var seed_phase := float(absi(str(identifier_value).hash()) % 628) / 100.0
        _apply_idle_phase(rig_value, _idle_clock * 1.15 + seed_phase, step)
        _overrides += 1

static func idle_targets(phase: float) -> Dictionary:
    var breath := sin(phase) * 0.018
    var sway := sin(phase * 0.63) * 0.012
    return {
        "left_leg_x": breath * 0.18,
        "right_leg_x": -breath * 0.18,
        "left_arm_x": -0.035 + breath,
        "right_arm_x": 0.035 - breath,
        "root_y": breath * 0.45,
        "root_z": sway,
    }

func _apply_idle_phase(rig: Dictionary, phase: float, delta: float) -> void:
    var breath := sin(phase) * 0.018
    var sway := sin(phase * 0.63) * 0.012
    var response := clampf(delta * 9.0, 0.0, 1.0)
    var left_leg := rig.get("left_leg", null) as Node3D
    var right_leg := rig.get("right_leg", null) as Node3D
    var left_arm := rig.get("left_arm", null) as Node3D
    var right_arm := rig.get("right_arm", null) as Node3D
    var root := rig.get("root", null) as Node3D
    if left_leg != null:
        left_leg.rotation.x = lerpf(left_leg.rotation.x, breath * 0.18, response)
    if right_leg != null:
        right_leg.rotation.x = lerpf(right_leg.rotation.x, -breath * 0.18, response)
    if left_arm != null:
        left_arm.rotation.x = lerpf(left_arm.rotation.x, -0.035 + breath, response)
    if right_arm != null:
        right_arm.rotation.x = lerpf(right_arm.rotation.x, 0.035 - breath, response)
    if root != null:
        root.position.y = lerpf(root.position.y, breath * 0.45, response)
        root.rotation.z = lerpf(root.rotation.z, sway, response)

func _apply_idle(rig: Dictionary, targets: Dictionary, delta: float) -> void:
    var response := clampf(delta * 9.0, 0.0, 1.0)
    var left_leg := rig.get("left_leg", null) as Node3D
    var right_leg := rig.get("right_leg", null) as Node3D
    var left_arm := rig.get("left_arm", null) as Node3D
    var right_arm := rig.get("right_arm", null) as Node3D
    var root := rig.get("root", null) as Node3D
    if left_leg != null:
        left_leg.rotation.x = lerpf(left_leg.rotation.x, float(targets.left_leg_x), response)
    if right_leg != null:
        right_leg.rotation.x = lerpf(right_leg.rotation.x, float(targets.right_leg_x), response)
    if left_arm != null:
        left_arm.rotation.x = lerpf(left_arm.rotation.x, float(targets.left_arm_x), response)
    if right_arm != null:
        right_arm.rotation.x = lerpf(right_arm.rotation.x, float(targets.right_arm_x), response)
    if root != null:
        root.position.y = lerpf(root.position.y, float(targets.root_y), response)
        root.rotation.z = lerpf(root.rotation.z, float(targets.root_z), response)

func runtime_snapshot() -> Dictionary:
    return {"dwelling_idle_overrides": _overrides}
