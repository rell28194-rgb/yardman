extends SceneTree

const RecoveryRuntime = preload("res://scripts/stream_recovery_runtime.gd")
var failures := 0

class FakeStreamer:
    extends Node
    var _failed: Dictionary = {}
    var _loaded: Dictionary = {}
    var _wanted: Dictionary = {}
    var _world_position := Vector2(1024.0, -512.0)
    var refresh_calls := 0
    var last_force := false

    func update_world(_x: float, _z: float, force := false) -> void:
        refresh_calls += 1
        last_force = force

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("STREAM_RECOVERY_RUNTIME_TEST: " + message)

func _run() -> void:
    var runtime := RecoveryRuntime.new()
    root.add_child(runtime)
    var streamer := FakeStreamer.new()
    root.add_child(streamer)
    var key := "3:7"
    streamer._wanted[key] = true
    streamer._failed[key] = true

    var armed := runtime._service_streamer(streamer, "near-buildings", 10000)
    _check(int(armed.get("active_failures", 0)) == 1, "Failure was not armed")
    _check(int(armed.get("failures_recorded", 0)) == 1, "Failure counter did not increment")
    _check(streamer.refresh_calls == 0, "Streamer refreshed before retry deadline")

    runtime._service_streamer(streamer, "near-buildings", 10999)
    _check(streamer._failed.has(key), "Failure released before deadline")
    _check(streamer.refresh_calls == 0, "Streamer refreshed early")

    var released := runtime._service_streamer(streamer, "near-buildings", 11000)
    _check(not streamer._failed.has(key), "Failure remained blacklisted at retry deadline")
    _check(streamer.refresh_calls == 1 and streamer.last_force, "Retry did not force stationary world refresh")
    _check(int(released.get("retries_released", 0)) == 1, "Released retry was not counted")
    _check(int(released.get("forced_refreshes", 0)) == 1, "Forced refresh was not counted")

    streamer._failed[key] = true
    runtime._service_streamer(streamer, "near-buildings", 12000)
    var owner_snapshot := runtime.runtime_snapshot()
    _check(int(owner_snapshot.get("active_failures", 0)) == 1, "Runtime snapshot lost active failure")

    streamer._wanted.clear()
    var dropped := runtime._service_streamer(streamer, "near-buildings", 12100)
    _check(not streamer._failed.has(key), "Unwanted failure was retained")
    _check(int(dropped.get("stale_failures_dropped", 0)) == 1, "Dropped failure was not counted")

    streamer.queue_free()
    runtime.queue_free()
    if failures == 0:
        print("YARDMAN_STREAM_RECOVERY_RUNTIME_TEST PASS stationary_retry=1 counters=1 stale_drop=1 forced_refresh=1")
    quit(0 if failures == 0 else 1)
