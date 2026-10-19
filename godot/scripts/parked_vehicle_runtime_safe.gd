extends "res://scripts/parked_vehicle_runtime.gd"

# Roadside offsets can legitimately land outside a resident/valid terrain
# sample near coastlines and tile edges. Such candidates are not valid parked
# poses and must never be materialized into RenderingServer transforms.
func _reconcile(roads, active_xz: Vector2) -> void:
    super._reconcile(roads, active_xz)
    var scene := get_tree().current_scene
    if scene == null:
        return
    var terrain = scene.get("terrain")
    if terrain == null:
        return
    _drop_unsupported_entries(roads, terrain)

func _refresh_visuals(scene: Node, roads, terrain, active_xz: Vector2) -> void:
    _drop_unsupported_entries(roads, terrain)
    super._refresh_visuals(scene, roads, terrain, active_xz)

func _drop_unsupported_entries(roads, terrain) -> void:
    var invalid_ids: Array[String] = []
    for identifier_value in parked.keys():
        var entry: Dictionary = parked.get(identifier_value, {})
        var point_value = entry.get("position", null)
        if not point_value is Vector2:
            invalid_ids.append(str(identifier_value))
            continue
        var point: Vector2 = point_value
        var heading := float(entry.get("heading", NAN))
        if not is_finite(point.x) or not is_finite(point.y) or not is_finite(heading):
            invalid_ids.append(str(identifier_value))
            continue
        var deck_y := float(terrain.height_at(point.x, point.y)) + 0.46
        if not is_finite(deck_y):
            invalid_ids.append(str(identifier_value))
            continue
        var local: Vector3 = roads.world_to_local(point.x, point.y, deck_y)
        if not is_finite(local.x) or not is_finite(local.y) or not is_finite(local.z):
            invalid_ids.append(str(identifier_value))
    for identifier in invalid_ids:
        _destroy(identifier)
