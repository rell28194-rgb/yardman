extends "res://scripts/traffic_runtime.gd"

# RenderingServer rejects any non-finite Transform3D. Traffic is generated from
# streamed road records, so stale or malformed agent state must be rejected at
# the runtime boundary instead of reaching scene instances or MultiMesh data.
func _refresh_visuals(scene: Node, roads, terrain, active_xz: Vector2) -> void:
    var invalid_ids: Array[String] = []
    for identifier_value in agents.keys():
        var identifier := str(identifier_value)
        var agent: Dictionary = agents.get(identifier_value, {})
        var point_value = agent.get("position", null)
        if not point_value is Vector2:
            invalid_ids.append(identifier)
            continue
        var point: Vector2 = point_value
        var heading := float(agent.get("heading", NAN))
        var progress := float(agent.get("progress", NAN))
        if not is_finite(point.x) or not is_finite(point.y) or not is_finite(heading) or not is_finite(progress):
            invalid_ids.append(identifier)
            continue
        var terrain_y := float(terrain.height_at(point.x, point.y))
        var deck_y := road_deck_height(agent.get("record", {}), progress, terrain_y)
        if not is_finite(deck_y):
            invalid_ids.append(identifier)
            continue
        var local: Vector3 = roads.world_to_local(point.x, point.y, deck_y + 0.46)
        if not is_finite(local.x) or not is_finite(local.y) or not is_finite(local.z):
            invalid_ids.append(identifier)
    for identifier in invalid_ids:
        _destroy_agent(identifier)
    super._refresh_visuals(scene, roads, terrain, active_xz)
