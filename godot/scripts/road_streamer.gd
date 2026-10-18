extends "res://scripts/road_streamer_base.gd"

const PriorityPolicy = preload("res://scripts/stream_priority_policy.gd")
const PRIORITY_TELEPORT_FLOOR_M := 256.0
const PRIORITY_TELEPORT_SPEED_FACTOR := 2.0

var _priority_last_world_xz := Vector2.ZERO
var _priority_last_sample_msec := 0
var _priority_has_sample := false
var _priority_velocity_mps := Vector2.ZERO

func _priority_sample_motion(now_msec: int = -1) -> Dictionary:
    if target == null or not is_instance_valid(target):
        _priority_has_sample = false
        _priority_velocity_mps = Vector2.ZERO
        return {"world_xz": Vector2.ZERO, "velocity_mps": Vector2.ZERO}
    var world: PackedFloat64Array = coordinates.local_to_world(target.global_position)
    var world_xz := Vector2(float(world[0]), float(world[2]))
    var now := Time.get_ticks_msec() if now_msec < 0 else now_msec
    var velocity := Vector2.ZERO
    if _priority_has_sample:
        var elapsed := maxf(float(now - _priority_last_sample_msec) / 1000.0, 0.0)
        if elapsed > 0.000001:
            var displacement := world_xz.distance_to(_priority_last_world_xz)
            var teleport_limit := maxf(PRIORITY_TELEPORT_FLOOR_M,
                PriorityPolicy.MAX_PREDICTION_SPEED_MPS * elapsed * PRIORITY_TELEPORT_SPEED_FACTOR)
            if displacement <= teleport_limit:
                velocity = PriorityPolicy.estimate_velocity(_priority_last_world_xz, world_xz, elapsed)
    _priority_last_world_xz = world_xz
    _priority_last_sample_msec = now
    _priority_has_sample = true
    _priority_velocity_mps = velocity
    return {"world_xz": world_xz, "velocity_mps": velocity}

func _sort_priority_queue(world_xz: Vector2, velocity_mps: Vector2) -> void:
    _queue.sort_custom(func(a: String, b: String) -> bool:
        return PriorityPolicy.less(_key_tile(a), _key_tile(b), tile_size, world_xz, velocity_mps))

func _refresh_tiles(force: bool) -> void:
    if target == null or _tile_files.is_empty():
        return
    var motion := _priority_sample_motion()
    var world_xz: Vector2 = motion.world_xz
    var velocity_mps: Vector2 = motion.velocity_mps
    var current := coordinates.tile_for(world_xz.x, world_xz.y)
    var retry_due := _release_retryable_failures()
    if not force and not retry_due and current == _last_tile and load_radius == _last_radius:
        # The candidate set is unchanged, but the player's position and travel
        # direction within a 4 km tile can change which pending cell is most
        # urgent. Re-sort only; do not rebuild residency or start extra jobs.
        if _queue.size() > 1:
            _sort_priority_queue(world_xz, velocity_mps)
        return
    generation += 1
    _last_tile = current
    _last_radius = load_radius
    _wanted.clear()
    _queue.clear()
    for dz in range(-load_radius, load_radius + 1):
        for dx in range(-load_radius, load_radius + 1):
            var key := _tile_key(current.x + dx, current.y + dz)
            if _tile_files.has(key):
                _wanted[key] = true
                if not _loaded.has(key) and not _jobs.has(key) and str(_building.get("key", "")) != key and not _failed.has(key):
                    _queue.append(key)
    if _queue.size() > 1:
        _sort_priority_queue(world_xz, velocity_mps)
    for key in _loaded.keys():
        var tile := _key_tile(str(key))
        if maxi(absi(tile.x - current.x), absi(tile.y - current.y)) > load_radius + 1:
            _loaded[key].queue_free()
            _loaded.erase(key)
            _surface_indices.erase(key)
            tile_removed.emit(tile)
    for key in _failed.keys():
        if not _wanted.has(str(key)):
            _failed.erase(key)
            _failure_attempts.erase(str(key))
    if not _building.is_empty() and not _wanted.has(_building.key):
        _building.root.free()
        _building.clear()
