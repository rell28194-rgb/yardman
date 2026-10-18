extends SceneTree

const RoadStreamer = preload("res://scripts/road_streamer.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("STREAM_RETRY_TEST: " + message)

func _run() -> void:
    _check(RoadStreamer._failure_retry_delay_ms(1) == 1000, "First retry delay changed")
    _check(RoadStreamer._failure_retry_delay_ms(2) == 2000, "Second retry delay changed")
    _check(RoadStreamer._failure_retry_delay_ms(3) == 4000, "Third retry delay changed")
    _check(RoadStreamer._failure_retry_delay_ms(20) == 30000, "Retry delay did not cap at 30 seconds")

    var streamer := RoadStreamer.new()
    var key := "4:-2"
    streamer._failed[key] = true

    _check(not streamer._release_retryable_failures(10000), "Fresh failure became retryable immediately")
    var first: Dictionary = streamer._failed.get(key, {})
    _check(int(first.get("attempts", 0)) == 1, "Fresh failure did not record attempt one")
    _check(int(first.get("retry_at_msec", 0)) == 11000, "First retry deadline is not deterministic")
    _check(not streamer._release_retryable_failures(10999), "Failure retried before its deadline")
    _check(streamer._failed.has(key), "Failure disappeared before its deadline")
    _check(streamer._release_retryable_failures(11000), "Failure did not release exactly at retry deadline")
    _check(not streamer._failed.has(key), "Released failure remained blacklisted")

    # A second failure backs off rather than hot-looping the same broken asset.
    streamer._failed[key] = true
    _check(not streamer._release_retryable_failures(12000), "Second failure became retryable immediately")
    var second: Dictionary = streamer._failed.get(key, {})
    _check(int(second.get("attempts", 0)) == 2, "Retry attempt history was lost")
    _check(int(second.get("retry_at_msec", 0)) == 14000, "Second failure did not double the retry delay")

    # Successful residency clears historical backoff so a later unrelated I/O
    # failure starts from the short recovery delay again.
    streamer._failed.erase(key)
    var loaded_root := Node3D.new()
    streamer._loaded[key] = loaded_root
    streamer._release_retryable_failures(13000)
    _check(not streamer._failure_attempts.has(key), "Successful residency retained stale retry history")
    streamer._loaded.erase(key)
    loaded_root.free()

    streamer._failed[key] = true
    streamer._release_retryable_failures(20000)
    var after_success: Dictionary = streamer._failed.get(key, {})
    _check(int(after_success.get("attempts", 0)) == 1, "Post-success failure did not restart at attempt one")
    _check(int(after_success.get("retry_at_msec", 0)) == 21000, "Post-success retry did not use base delay")

    streamer.free()
    if failures == 0:
        print("YARDMAN_STREAM_RETRY_TEST PASS backoff=1 cap=1 deadline=1 success_reset=1 road_terrain_base=1")
    quit(0 if failures == 0 else 1)
