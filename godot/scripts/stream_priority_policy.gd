extends RefCounted
class_name YardmanStreamPriorityPolicy

# Immediate-I/O ordering for already-wanted stream cells. This never expands
# residency; it only ranks the existing candidate set. National Jamaica traces
# showed long straight-line extrapolation over-steers on curving roads, so the
# production candidate intentionally uses only a short 2 s horizon.
const PREDICTION_HORIZON_S := 2.0
const WEIGHT_NOW := 1.0
const WEIGHT_PREDICTED := 0.20
const MAX_PREDICTION_SPEED_MPS := 120.0
const SCORE_EPSILON := 0.000001

static func distance_squared_to_tile_aabb(world_xz: Vector2, tile: Vector2i, tile_size: float) -> float:
    if tile_size <= 0.0:
        return INF
    var min_x := float(tile.x) * tile_size
    var min_z := float(tile.y) * tile_size
    var max_x := min_x + tile_size
    var max_z := min_z + tile_size
    var dx := 0.0
    var dz := 0.0
    if world_xz.x < min_x:
        dx = min_x - world_xz.x
    elif world_xz.x > max_x:
        dx = world_xz.x - max_x
    if world_xz.y < min_z:
        dz = min_z - world_xz.y
    elif world_xz.y > max_z:
        dz = world_xz.y - max_z
    return dx * dx + dz * dz

static func clamp_prediction_velocity(velocity_mps: Vector2) -> Vector2:
    var speed := velocity_mps.length()
    if not is_finite(speed) or speed <= 0.0:
        return Vector2.ZERO
    if speed <= MAX_PREDICTION_SPEED_MPS:
        return velocity_mps
    return velocity_mps * (MAX_PREDICTION_SPEED_MPS / speed)

static func estimate_velocity(previous_world_xz: Vector2, current_world_xz: Vector2,
        elapsed_seconds: float) -> Vector2:
    if elapsed_seconds <= 0.000001 or not is_finite(elapsed_seconds):
        return Vector2.ZERO
    var raw := (current_world_xz - previous_world_xz) / elapsed_seconds
    return clamp_prediction_velocity(raw)

static func score(tile: Vector2i, tile_size: float, world_xz: Vector2,
        velocity_mps: Vector2) -> float:
    if tile_size <= 0.0:
        return INF
    var velocity := clamp_prediction_velocity(velocity_mps)
    var predicted := world_xz + velocity * PREDICTION_HORIZON_S
    return (
        WEIGHT_NOW * distance_squared_to_tile_aabb(world_xz, tile, tile_size)
        + WEIGHT_PREDICTED * distance_squared_to_tile_aabb(predicted, tile, tile_size)
    )

static func less(a: Vector2i, b: Vector2i, tile_size: float, world_xz: Vector2,
        velocity_mps: Vector2) -> bool:
    var a_score := score(a, tile_size, world_xz, velocity_mps)
    var b_score := score(b, tile_size, world_xz, velocity_mps)
    if absf(a_score - b_score) > SCORE_EPSILON:
        return a_score < b_score
    # Stable deterministic tie-break independent of Dictionary iteration order.
    if a.y != b.y:
        return a.y < b.y
    return a.x < b.x
