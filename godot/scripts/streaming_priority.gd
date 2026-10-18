extends RefCounted
class_name YardmanStreamingPriority

# Compatibility-safe predictive ordering for streamed world cells. This does
# not change residency radius, geographic authority, or LOD policy; it only
# decides which already-wanted work reaches I/O first.
const STOP_SPEED_MPS := 0.35
const FULL_BIAS_SPEED_MPS := 22.0
const MAX_MOTION_WEIGHT := 0.72
const SCORE_EPSILON := 0.001

static func cell_center(cell: Vector2i, cell_size: float) -> Vector2:
    return (Vector2(cell) + Vector2(0.5, 0.5)) * cell_size

static func containing_cell(point: Vector2, cell_size: float) -> Vector2i:
    if cell_size <= 0.0 or not point.is_finite():
        return Vector2i.ZERO
    return Vector2i(floori(point.x / cell_size), floori(point.y / cell_size))

static func cell_distance(cell: Vector2i, point: Vector2, cell_size: float) -> float:
    if cell_size <= 0.0 or not point.is_finite():
        return INF
    var minimum := Vector2(cell) * cell_size
    var maximum := minimum + Vector2.ONE * cell_size
    var dx := maxf(maxf(minimum.x - point.x, 0.0), point.x - maximum.x)
    var dy := maxf(maxf(minimum.y - point.y, 0.0), point.y - maximum.y)
    return Vector2(dx, dy).length()

static func target_velocity(target: Node3D) -> Vector2:
    if target is CharacterBody3D:
        var velocity := (target as CharacterBody3D).velocity
        return Vector2(velocity.x, velocity.z)
    if target is RigidBody3D:
        var velocity := (target as RigidBody3D).linear_velocity
        return Vector2(velocity.x, velocity.z)
    return Vector2.ZERO

static func priority_score(cell: Vector2i, target_world: Vector2, velocity_world: Vector2,
        cell_size: float, prediction_seconds: float = 6.0) -> float:
    if cell_size <= 0.0 or not target_world.is_finite() or not velocity_world.is_finite():
        return INF
    # Never speculate ahead of geometry underneath the target. This is a hard
    # residency invariant, not a tunable heuristic.
    if cell == containing_cell(target_world, cell_size):
        return 0.0
    # Distance to the cell footprint is what matters for streaming. Using the
    # center of a 4 km national tile can make geometry 5 m away look ~2 km away.
    var current_distance := cell_distance(cell, target_world, cell_size)
    var speed := velocity_world.length()
    if speed <= STOP_SPEED_MPS:
        return current_distance

    var horizon := clampf(prediction_seconds, 0.0, 12.0)
    var lead_distance := minf(speed * horizon, cell_size * 0.85)
    var predicted := target_world + velocity_world / speed * lead_distance
    var predicted_distance := cell_distance(cell, predicted, cell_size)
    var motion_weight := clampf(speed / FULL_BIAS_SPEED_MPS, 0.0, 1.0) * MAX_MOTION_WEIGHT
    return lerpf(current_distance, predicted_distance, motion_weight)

static func less(a: Vector2i, b: Vector2i, target_world: Vector2, velocity_world: Vector2,
        cell_size: float, prediction_seconds: float = 6.0) -> bool:
    if cell_size > 0.0 and target_world.is_finite():
        var occupied := containing_cell(target_world, cell_size)
        if a == occupied and b != occupied:
            return true
        if b == occupied and a != occupied:
            return false

    var score_a := priority_score(a, target_world, velocity_world, cell_size, prediction_seconds)
    var score_b := priority_score(b, target_world, velocity_world, cell_size, prediction_seconds)
    if absf(score_a - score_b) > SCORE_EPSILON:
        return score_a < score_b

    # Stable ties use centers only after footprint relevance has tied. This
    # preserves determinism without reintroducing center-distance bias.
    var distance_a := cell_center(a, cell_size).distance_squared_to(target_world)
    var distance_b := cell_center(b, cell_size).distance_squared_to(target_world)
    if absf(distance_a - distance_b) > SCORE_EPSILON:
        return distance_a < distance_b
    if a.x != b.x:
        return a.x < b.x
    return a.y < b.y
