extends RefCounted
class_name YardmanVehicleRuntimeContract

# Vehicle-production boundary: this contract describes vehicle-local nodes that
# the game may consume without depending on streamed terrain or road state.
const REQUIRED_HOOKS := ["CameraMount", "ExitPoint", "DriverSeat"]
const REQUIRED_RUNTIME_CHECKS := ["forward", "reverse", "steering", "braking", "park_exit_reenter", "reset_despawn"]
const ACCEPTANCE_SCORE := 90
const HOOK_ROLE_META := "yardman_runtime_hook"
const VISUAL_ROLE_META := "yardman_visual_rig"

static func ensure_hooks(vehicle: Node3D, bounds: AABB) -> Dictionary:
    var result := {}
    var center := bounds.get_center()
    var half_width := maxf(bounds.size.x * 0.5, 0.8)
    var half_length := maxf(bounds.size.z * 0.5, 1.8)
    var roof_y := maxf(bounds.position.y + bounds.size.y, 1.25)
    var poses := {
        "CameraMount": Vector3(center.x, roof_y + 0.45, center.z + half_length * 0.42),
        "ExitPoint": Vector3(-half_width - 0.75, maxf(bounds.position.y + 0.15, 0.15), center.z + 0.20),
        "DriverSeat": Vector3(-half_width * 0.32, maxf(bounds.position.y + bounds.size.y * 0.46, 0.55), center.z + half_length * 0.10),
    }
    for hook_name in REQUIRED_HOOKS:
        var hook := vehicle.get_node_or_null(hook_name) as Marker3D
        if hook == null:
            hook = Marker3D.new()
            hook.name = hook_name
            vehicle.add_child(hook)
        hook.set_meta(HOOK_ROLE_META, hook_name)
        hook.position = poses[hook_name]
        result[hook_name] = hook
    return result

static func _runtime_role(node: Node) -> String:
    var tagged := str(node.get_meta(HOOK_ROLE_META, ""))
    if REQUIRED_HOOKS.has(tagged):
        return tagged
    var node_name := str(node.name)
    for hook_name in REQUIRED_HOOKS:
        if node_name == hook_name or node_name.begins_with(hook_name):
            return hook_name
    return ""

static func audit(vehicle: Node3D) -> Dictionary:
    var counts := {}
    for hook_name in REQUIRED_HOOKS:
        counts[hook_name] = 0
    var visual_rig_count := 0
    for child in vehicle.get_children():
        if child is Marker3D:
            var role := _runtime_role(child)
            if not role.is_empty():
                counts[role] = int(counts.get(role, 0)) + 1
        if child is Node3D:
            var child_name := str(child.name)
            if bool(child.get_meta(VISUAL_ROLE_META, false)) or child_name == "VisualRig" or child_name.begins_with("VisualRig"):
                visual_rig_count += 1
    var duplicates := []
    var missing := []
    for hook_name in REQUIRED_HOOKS:
        var count := int(counts.get(hook_name, 0))
        if count == 0:
            missing.append(hook_name)
        elif count > 1:
            duplicates.append(hook_name)
    return {
        "ready": missing.is_empty() and duplicates.is_empty() and visual_rig_count == 1,
        "missing_hooks": missing,
        "duplicate_hooks": duplicates,
        "visual_rig_count": visual_rig_count,
        "hook_counts": counts,
    }

static func grade(vehicle: Node3D, evidence: Dictionary) -> Dictionary:
    var local_audit := audit(vehicle)
    var failures := []
    var score := 100
    if not bool(local_audit.ready):
        failures.append("node_contract")
        score -= 30
    for check_name in REQUIRED_RUNTIME_CHECKS:
        if not bool(evidence.get(check_name, false)):
            failures.append(check_name)
            score -= 10
    if not bool(evidence.get("selector_safe", false)):
        failures.append("selector_safe")
        score -= 10
    if not bool(evidence.get("collider_rig_aligned", false)):
        failures.append("collider_rig_aligned")
        score -= 10
    if not bool(evidence.get("identity_verified", false)):
        failures.append("identity_verified")
        score -= 20
    if not bool(evidence.get("beta1_provenance", false)) or not bool(evidence.get("beta2_provenance", false)):
        failures.append("dual_source_provenance")
        score -= 20
    if not bool(evidence.get("crown_non_regression", false)):
        failures.append("crown_non_regression")
        score -= 30
    score = maxi(score, 0)
    return {
        "score": score,
        "grade": "A" if score >= 95 else ("B" if score >= ACCEPTANCE_SCORE else ("C" if score >= 75 else "F")),
        "accepted": score >= ACCEPTANCE_SCORE and failures.is_empty(),
        "failures": failures,
        "node_audit": local_audit,
    }
