extends RefCounted
class_name YardmanVehicleRuntimeContract

# Vehicle-production boundary: this contract describes vehicle-local nodes that
# the game may consume without depending on streamed terrain or road state.
const REQUIRED_HOOKS := ["CameraMount", "ExitPoint", "DriverSeat"]

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
        hook.position = poses[hook_name]
        result[hook_name] = hook
    return result

static func audit(vehicle: Node3D) -> Dictionary:
    var duplicates := []
    var missing := []
    for hook_name in REQUIRED_HOOKS:
        var matches := vehicle.find_children(hook_name, "Marker3D", true, false)
        if matches.is_empty():
            missing.append(hook_name)
        elif matches.size() > 1:
            duplicates.append(hook_name)
    var visual_rigs := vehicle.find_children("VisualRig", "Node3D", true, false)
    return {
        "ready": missing.is_empty() and duplicates.is_empty() and visual_rigs.size() <= 1,
        "missing_hooks": missing,
        "duplicate_hooks": duplicates,
        "visual_rig_count": visual_rigs.size(),
    }
