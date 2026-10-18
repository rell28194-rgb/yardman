extends Node
class_name YardmanPredictiveStreamingRuntime

const Priority = preload("res://scripts/streaming_priority.gd")

# Queue ordering is intentionally independent from residency budgets. The
# existing thermal/quality system remains authoritative for how much is loaded.
var refresh_interval := 0.10
var road_prediction_seconds := 8.0
var building_prediction_seconds := 2.5
var _clock := 0.0
var _last_snapshot: Dictionary = {}

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS

func _process(delta: float) -> void:
    _clock += delta
    if _clock < refresh_interval:
        return
    _clock = 0.0
    var scene := get_tree().current_scene
    if scene == null:
        return
    var snapshot := {}
    _reprioritize(scene.get("roads"), "roads", road_prediction_seconds, snapshot)
    _reprioritize(scene.get("terrain"), "terrain", road_prediction_seconds, snapshot)
    _reprioritize(scene.get("buildings"), "buildings", building_prediction_seconds, snapshot)
    _last_snapshot = snapshot

func runtime_snapshot() -> Dictionary:
    return _last_snapshot.duplicate(true)

func _reprioritize(streamer: Variant, label: String, prediction_seconds: float,
        snapshot: Dictionary) -> void:
    if not streamer is Node:
        return
    var node := streamer as Node
    var target_value: Variant = node.get("target")
    var coordinates: Variant = node.get("coordinates")
    var queue_value: Variant = node.get("_queue")
    if not target_value is Node3D or coordinates == null or not queue_value is Array:
        return
    var queue: Array = queue_value
    if queue.size() < 2:
        snapshot[label] = {"queued": queue.size(), "reprioritized": false}
        return

    var target := target_value as Node3D
    var world: PackedFloat64Array = coordinates.local_to_world(target.global_position)
    if world.size() < 3:
        return
    var target_world := Vector2(float(world[0]), float(world[2]))
    var velocity_world := Priority.target_velocity(target)
    var cell_size := 0.0
    var decode_method := ""
    if node.has_method("_key_tile"):
        cell_size = float(node.get("tile_size"))
        decode_method = "_key_tile"
    elif node.has_method("_cell"):
        cell_size = float(node.get("cell_size"))
        decode_method = "_cell"
    if cell_size <= 0.0 or decode_method.is_empty():
        return

    queue.sort_custom(func(a: Variant, b: Variant) -> bool:
        var cell_a: Vector2i = node.call(decode_method, str(a))
        var cell_b: Vector2i = node.call(decode_method, str(b))
        return Priority.less(cell_a, cell_b, target_world, velocity_world, cell_size, prediction_seconds)
    )
    node.set("_queue", queue)
    snapshot[label] = {
        "queued": queue.size(),
        "reprioritized": true,
        "first": str(queue[0]),
        "speed_mps": velocity_world.length(),
        "cell_size_m": cell_size,
    }
