extends Node
class_name YardmanTerrainPhysicsRuntime

const REFRESH_INTERVAL_S := 0.12
const BOUNDARY_WARM_M := 180.0

var _clock := 0.0
var _last_active := -1
var _last_dormant := -1
var _last_tile := Vector2i(2147483647, 2147483647)
var _last_residency_signature := ""

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS

func _process(delta: float) -> void:
    _clock += delta
    if _clock < REFRESH_INTERVAL_S:
        return
    _clock = 0.0
    _refresh_physics_residency()

func _refresh_physics_residency() -> void:
    var scene := get_tree().current_scene
    if scene == null:
        _last_residency_signature = ""
        return
    var terrain = scene.get("terrain")
    if terrain == null or terrain.target == null:
        _last_residency_signature = ""
        return
    var world: PackedFloat64Array = terrain.coordinates.local_to_world(terrain.target.global_position)
    if world.size() < 3:
        return
    var point := Vector2(float(world[0]), float(world[2]))
    var current: Vector2i = terrain.coordinates.tile_for(point.x, point.y)
    var wanted := collision_tiles_for(point, current, float(terrain.tile_size), BOUNDARY_WARM_M)
    var loaded_value = terrain.get("_loaded")
    if not loaded_value is Dictionary:
        return
    var loaded: Dictionary = loaded_value

    # Collision state only changes when the player crosses the warm boundary or
    # terrain residency changes. Avoid walking every loaded tile at ~8 Hz while
    # driving through the interior of the same 2 km tile.
    var loaded_keys: Array[String] = []
    for key_value in loaded.keys():
        loaded_keys.append(str(key_value))
    loaded_keys.sort()
    var wanted_keys: Array[String] = []
    for tile_value in wanted.keys():
        var tile: Vector2i = tile_value
        wanted_keys.append("%d:%d" % [tile.x, tile.y])
    wanted_keys.sort()
    var signature := "%d:%d|%s|%s" % [current.x, current.y, ",".join(wanted_keys), ",".join(loaded_keys)]
    if signature == _last_residency_signature:
        return
    _last_residency_signature = signature

    var active := 0
    var dormant := 0
    for key_value in loaded.keys():
        var key := str(key_value)
        var tile := _key_tile(key)
        var enabled := wanted.has(tile)
        var root = loaded[key_value]
        if not root is Node:
            continue
        for child in (root as Node).get_children():
            if not child is StaticBody3D:
                continue
            _set_body_enabled(child as StaticBody3D, enabled)
            if enabled:
                active += 1
            else:
                dormant += 1
    _last_active = active
    _last_dormant = dormant
    _last_tile = current

static func collision_tiles_for(point: Vector2, current: Vector2i, tile_size: float, warm_m: float) -> Dictionary:
    var result := {current: true}
    if tile_size <= 0.0 or warm_m <= 0.0:
        return result
    var local_x := point.x - float(current.x) * tile_size
    var local_z := point.y - float(current.y) * tile_size
    var left := local_x <= warm_m
    var right := tile_size - local_x <= warm_m
    var top := local_z <= warm_m
    var bottom := tile_size - local_z <= warm_m
    if left:
        result[current + Vector2i(-1, 0)] = true
    if right:
        result[current + Vector2i(1, 0)] = true
    if top:
        result[current + Vector2i(0, -1)] = true
    if bottom:
        result[current + Vector2i(0, 1)] = true
    if left and top:
        result[current + Vector2i(-1, -1)] = true
    if left and bottom:
        result[current + Vector2i(-1, 1)] = true
    if right and top:
        result[current + Vector2i(1, -1)] = true
    if right and bottom:
        result[current + Vector2i(1, 1)] = true
    return result

static func _key_tile(key: String) -> Vector2i:
    var parts := key.split(":")
    if parts.size() != 2:
        return Vector2i(2147483647, 2147483647)
    return Vector2i(int(parts[0]), int(parts[1]))

func _set_body_enabled(body: StaticBody3D, enabled: bool) -> void:
    if bool(body.get_meta("yardman_physics_active", true)) == enabled:
        return
    body.set_meta("yardman_physics_active", enabled)
    body.collision_layer = 1 if enabled else 0
    body.collision_mask = 0
    for child in body.get_children():
        if child is CollisionShape3D:
            (child as CollisionShape3D).set_deferred("disabled", not enabled)

func runtime_snapshot() -> Dictionary:
    return {
        "terrain_collision_active": maxi(_last_active, 0),
        "terrain_collision_dormant": maxi(_last_dormant, 0),
        "active_tile": _last_tile,
        "boundary_warm_m": BOUNDARY_WARM_M,
    }
