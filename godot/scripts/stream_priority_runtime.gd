extends Node
class_name YardmanStreamPriorityRuntime

const Priority = preload("res://scripts/streaming_priority.gd")
const POLL_SECONDS := 0.20

var _clock := 0.0
var sorts_performed := 0

func _process(delta: float) -> void:
    _clock += delta
    if _clock < POLL_SECONDS:
        return
    _clock = 0.0
    var scene := get_tree().current_scene
    if scene == null:
        return
    for label in ["roads", "terrain", "buildings"]:
        var streamer = scene.get(label)
        if streamer is Object and reprioritize_streamer(streamer, label):
            sorts_performed += 1

static func _key_cell(key: String) -> Vector2i:
    var parts := key.split(":")
    if parts.size() != 2:
        return Vector2i.ZERO
    return Vector2i(int(parts[0]), int(parts[1]))

static func reprioritize_streamer(streamer: Object, label: String) -> bool:
    if streamer == null:
        return false
    var queue_variant = streamer.get("_queue")
    if not queue_variant is Array:
        return false
    var queue: Array = queue_variant
    if queue.size() < 2:
        return false

    var target_variant = streamer.get("target")
    if not target_variant is Node3D:
        return false
    var target := target_variant as Node3D
    if not is_instance_valid(target):
        return false

    var coordinates = streamer.get("coordinates")
    if coordinates == null or not coordinates.has_method("local_to_world"):
        return false
    var world_variant = coordinates.call("local_to_world", target.global_position)
    if not world_variant is PackedFloat64Array:
        return false
    var world: PackedFloat64Array = world_variant
    if world.size() < 3:
        return false
    var target_world := Vector2(float(world[0]), float(world[2]))
    if not target_world.is_finite():
        return false

    var cell_size := 0.0
    if label == "buildings":
        cell_size = float(streamer.get("cell_size"))
    else:
        cell_size = float(streamer.get("tile_size"))
    if cell_size <= 0.0 or not is_finite(cell_size):
        return false

    var velocity_world := Priority.target_velocity(target)
    queue.sort_custom(func(a, b) -> bool:
        return Priority.less(_key_cell(str(a)), _key_cell(str(b)), target_world, velocity_world, cell_size))
    return true
