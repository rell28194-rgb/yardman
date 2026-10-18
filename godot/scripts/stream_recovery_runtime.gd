extends Node
class_name YardmanStreamRecoveryRuntime

const RetryPolicy = preload("res://scripts/stream_retry_policy.gd")

var _clock := 0.0
var _attempts_by_owner: Dictionary = {}
var _stats_by_owner: Dictionary = {}
var _scene_id := 0

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS

func _process(delta: float) -> void:
    _clock += delta
    if _clock < 0.20:
        return
    _clock = 0.0
    var scene := get_tree().current_scene
    var next_scene_id := scene.get_instance_id() if scene != null else 0
    if next_scene_id != _scene_id:
        _attempts_by_owner.clear()
        _stats_by_owner.clear()
        _scene_id = next_scene_id
    if scene != null:
        var buildings = scene.get("buildings")
        if buildings is Object:
            _service_streamer(buildings as Object, "near-buildings")
    var hlod := get_node_or_null("/root/BuildingHLOD")
    if hlod != null:
        _service_streamer(hlod, "building-hlod")

func _owner_key(streamer: Object, label: String) -> String:
    return "%s:%d" % [label, streamer.get_instance_id()]

func _service_streamer(streamer: Object, label: String, now_msec: int = -1) -> Dictionary:
    if streamer == null or not is_instance_valid(streamer):
        return {}
    var failed_value = streamer.get("_failed")
    var loaded_value = streamer.get("_loaded")
    if not failed_value is Dictionary or not loaded_value is Dictionary:
        return {}
    var wanted_value = streamer.get("_wanted")
    if not wanted_value is Dictionary:
        wanted_value = streamer.get_meta("yardman_hlod_wanted", {})
    if not wanted_value is Dictionary:
        wanted_value = {}

    var owner := _owner_key(streamer, label)
    if not _attempts_by_owner.has(owner):
        _attempts_by_owner[owner] = {}
    if not _stats_by_owner.has(owner):
        _stats_by_owner[owner] = {
            "label": label,
            "failures_recorded": 0,
            "retries_released": 0,
            "stale_failures_dropped": 0,
            "forced_refreshes": 0,
        }
    var attempts: Dictionary = _attempts_by_owner[owner]
    var stats: Dictionary = _stats_by_owner[owner]
    var failed: Dictionary = failed_value
    var loaded: Dictionary = loaded_value
    var wanted: Dictionary = wanted_value

    RetryPolicy.forget_unwanted(failed, attempts, wanted, stats)
    var released := RetryPolicy.release_due(failed, attempts, loaded, stats, now_msec)
    streamer.set("_failed", failed)
    _attempts_by_owner[owner] = attempts

    if released > 0 and streamer.has_method("update_world"):
        var world_value = streamer.get("_world_position")
        if world_value is Vector2:
            var world := world_value as Vector2
            streamer.call("update_world", world.x, world.y, true)
            stats["forced_refreshes"] = int(stats.get("forced_refreshes", 0)) + 1
    _stats_by_owner[owner] = stats
    return RetryPolicy.snapshot(failed, attempts, stats)

func runtime_snapshot() -> Dictionary:
    var owners: Dictionary = {}
    var total_active := 0
    var total_released := 0
    for owner in _stats_by_owner.keys():
        var stats: Dictionary = (_stats_by_owner[owner] as Dictionary).duplicate(true)
        var attempts: Dictionary = _attempts_by_owner.get(owner, {})
        stats["tracked_attempts"] = attempts.size()
        owners[owner] = stats
        total_active += int(stats.get("active_failures", 0))
        total_released += int(stats.get("retries_released", 0))
    return {
        "owners": owners,
        "active_failures": total_active,
        "retries_released": total_released,
        "scene_id": _scene_id,
    }
