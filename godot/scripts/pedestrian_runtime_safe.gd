extends "res://scripts/pedestrian_runtime.gd"

# Inferred roadside walking corridors can cross a coastline or a temporarily
# non-resident terrain sample. Reject those population candidates before any
# AnimatableBody3D or MultiMesh transform reaches RenderingServer.
func _reconcile_population(scene: Node, roads, active_xz: Vector2) -> void:
    super._reconcile_population(scene, roads, active_xz)
    var terrain = scene.get("terrain")
    if terrain != null:
        _drop_unsupported_agents(roads, terrain)

func _refresh_visuals(scene: Node, roads, terrain, active_xz: Vector2, delta: float) -> void:
    _drop_unsupported_agents(roads, terrain)
    super._refresh_visuals(scene, roads, terrain, active_xz, delta)

func _drop_unsupported_agents(roads, terrain) -> void:
    var invalid_ids: Array[String] = []
    for identifier_value in agents.keys():
        var agent: Dictionary = agents.get(identifier_value, {})
        var point_value = agent.get("position", null)
        if not point_value is Vector2:
            invalid_ids.append(str(identifier_value))
            continue
        var point: Vector2 = point_value
        var heading := float(agent.get("heading", NAN))
        var progress := float(agent.get("progress", NAN))
        if not is_finite(point.x) or not is_finite(point.y) or not is_finite(heading) or not is_finite(progress):
            invalid_ids.append(str(identifier_value))
            continue
        var ground_y := float(terrain.height_at(point.x, point.y)) + 0.04
        if not is_finite(ground_y):
            invalid_ids.append(str(identifier_value))
            continue
        var local: Vector3 = roads.world_to_local(point.x, point.y, ground_y)
        if not is_finite(local.x) or not is_finite(local.y) or not is_finite(local.z):
            invalid_ids.append(str(identifier_value))
    for identifier in invalid_ids:
        _destroy_agent(identifier)
