extends RefCounted
class_name YardmanVehicleStanceRuntime

# Repositions the shared fallback wheel rig to each production profile's actual
# wheelbase/track and normalizes tyre radius. This keeps the public fallback
# honest while dedicated hero rigs are recovered privately.
static func apply(root: Node3D, profile: Dictionary) -> Dictionary:
    var result := {
        "vehicle_id": str(profile.get("id", "legacy_sedan")),
        "wheels_positioned": 0,
        "wheelbase_world_m": 0.0,
        "track_world_m": 0.0,
        "radius_world_m": 0.0,
    }
    if root == null:
        return result
    if bool(root.get_meta("yardman_dedicated_vehicle_mesh", false)):
        # Source rigs are already normalized to metres. The fallback stance
        # layer must not move authored axles or replace spindle transforms.
        result["dedicated_mesh"] = true
        result["wheelbase_world_m"] = float(root.get("wheelbase_m"))
        result["track_world_m"] = float(root.get("track_width_m"))
        result["radius_world_m"] = float(root.get("wheel_radius_m"))
        root.set_meta("yardman_stance_vehicle_id", str(result.vehicle_id))
        root.set_meta("yardman_stance_stats", result.duplicate(true))
        return result
    var spins_value = root.get("wheels")
    if not spins_value is Array:
        return result
    var spins: Array = spins_value
    if spins.is_empty():
        return result

    var sx := maxf(absf(root.scale.x), 0.001)
    var sy := maxf(absf(root.scale.y), 0.001)
    var sz := maxf(absf(root.scale.z), 0.001)
    var wheelbase_world := maxf(float(profile.get("wheelbase_m", 2.56)), 1.8)
    var track_world := maxf(float(profile.get("track_width_m", 1.44)), 1.1)
    var radius_world := clampf(float(profile.get("wheel_radius_m", 0.35)), 0.24, 0.55)
    var wheelbase_local := wheelbase_world / sz
    var track_local := track_world / sx
    var source_radius := maxf(float(root.get("wheel_radius_m")), 0.01)
    var radius_scale := radius_world / maxf(source_radius * sy, 0.01)
    var positioned := 0

    for spin_value in spins:
        if not spin_value is Node3D:
            continue
        var spin := spin_value as Node3D
        var pivot := spin.get_parent() as Node3D
        if pivot == null:
            continue
        var label := pivot.name.to_lower()
        var current_x := pivot.position.x
        var current_z := pivot.position.z
        if label.contains("front"):
            pivot.position.z = -wheelbase_local * 0.5
        elif label.contains("rear"):
            pivot.position.z = wheelbase_local * 0.5
        elif current_z < 0.0:
            pivot.position.z = -wheelbase_local * 0.5
        elif current_z > 0.0:
            pivot.position.z = wheelbase_local * 0.5
        else:
            continue

        if label.contains("left"):
            pivot.position.x = -track_local * 0.5
        elif label.contains("right"):
            pivot.position.x = track_local * 0.5
        elif current_x < 0.0:
            pivot.position.x = -track_local * 0.5
        elif current_x > 0.0:
            pivot.position.x = track_local * 0.5
        else:
            continue

        spin.scale = Vector3.ONE * radius_scale
        positioned += 1

    result["wheels_positioned"] = positioned
    result["wheelbase_world_m"] = wheelbase_world
    result["track_world_m"] = track_world
    result["radius_world_m"] = radius_world
    root.set_meta("yardman_stance_vehicle_id", str(result.vehicle_id))
    root.set_meta("yardman_stance_stats", result.duplicate(true))
    return result
