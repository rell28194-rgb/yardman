extends SceneTree

const Harness = preload("res://scripts/streaming_adversarial_harness.gd")
const RetryPolicy = preload("res://scripts/stream_retry_policy.gd")
const RecoveryRuntime = preload("res://scripts/stream_recovery_runtime.gd")

var failures := 0

class FakeStreamer:
    extends Node
    var _failed: Dictionary = {}
    var _loaded: Dictionary = {}
    var _wanted: Dictionary = {}
    var _world_position := Vector2(10.0, 20.0)
    var refresh_calls := 0
    var last_refresh := Vector3.ZERO

    func update_world(x: float, z: float, force: bool = false) -> void:
        refresh_calls += 1
        last_refresh = Vector3(x, z, 1.0 if force else 0.0)

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("STREAMING_ADVERSARIAL_TEST: " + message)

func _run() -> void:
    _test_schema_rejection()
    _test_deterministic_replay()
    _test_backoff_schedule_and_cap()
    _test_repeated_failure_progression()
    _test_retry_timing_and_stale_cleanup()
    _test_legacy_failure_conversion()
    _test_loaded_tile_clears_failure()
    _test_recovery_runtime_integration()
    print("YARDMAN_STREAMING_ADVERSARIAL_TEST %s schema=1 deterministic=1 backoff=1 repeated_failure=1 retry=1 stale=1 orphan_cleanup=1 legacy=1 loaded_failure_oracle=1 runtime_integration=1" % (
        "PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)

func _test_schema_rejection() -> void:
    var malformed := {
        "schema_version": 1,
        "name": "malformed-llm-proposal",
        "actions": [
            {"op": "advance_ms", "value": -1},
            {"op": "invent_engine_api", "key": "tile:0:0"},
            {"op": "fail", "key": ""},
        ],
    }
    var result := Harness.run_scenario(malformed)
    _check(not bool(result.get("accepted", true)), "malformed proposal was accepted")
    _check((result.get("trace", []) as Array).is_empty(), "rejected proposal mutated runtime state")
    _check((result.get("errors", []) as Array).size() >= 3, "schema rejection lost expected diagnostics")

func _test_deterministic_replay() -> void:
    var scenario := {
        "schema_version": 1,
        "name": "replay",
        "actions": [
            {"op": "set_wanted", "keys": ["tile:a", "tile:b"]},
            {"op": "fail", "key": "tile:a", "category": "road"},
            {"op": "advance_ms", "value": 1000},
            {"op": "release_due"},
            {"op": "fail", "key": "tile:a", "category": "road"},
            {"op": "fail", "key": "tile:b", "category": "terrain"},
            {"op": "advance_ms", "value": 2000},
            {"op": "service"},
        ],
    }
    var first := Harness.run_scenario(scenario)
    var second := Harness.run_scenario(scenario)
    _check(bool(first.get("accepted", false)) and bool(second.get("accepted", false)), "valid replay scenario rejected")
    _check(str(first.get("fingerprint", "")) == str(second.get("fingerprint", "")), "same scenario produced different final fingerprints")
    _check(JSON.stringify(first.get("trace", [])) == JSON.stringify(second.get("trace", [])), "same scenario produced different traces")
    _check((first.get("invariant_errors", []) as Array).is_empty(), "deterministic replay violated state invariants")

func _test_backoff_schedule_and_cap() -> void:
    var expected := [1000, 2000, 4000, 8000, 16000, 30000, 30000, 30000]
    for index in range(expected.size()):
        var attempts := index + 1
        _check(RetryPolicy.retry_delay_ms(attempts) == int(expected[index]),
            "retry backoff mismatch at attempt %d" % attempts)
    _check(RetryPolicy.retry_delay_ms(0) == RetryPolicy.RETRY_BASE_MS,
        "non-positive attempt did not clamp to base retry delay")
    _check(RetryPolicy.retry_delay_ms(64) == RetryPolicy.RETRY_MAX_MS,
        "large attempt count escaped retry cap")

func _test_repeated_failure_progression() -> void:
    var scenario := {
        "schema_version": 1,
        "name": "repeated-failure-progresses-backoff",
        "actions": [
            {"op": "set_wanted", "keys": ["tile:repeat"]},
            {"op": "fail", "key": "tile:repeat", "category": "road"},
            {"op": "fail", "key": "tile:repeat", "category": "road"},
        ],
    }
    var result := Harness.run_scenario(scenario)
    _check(bool(result.get("accepted", false)), "repeated failure scenario rejected")
    _check((result.get("invariant_errors", []) as Array).is_empty(), "repeated failure violated invariants")
    var failed: Dictionary = result.get("failed", {})
    var attempts: Dictionary = result.get("attempts", {})
    var state: Dictionary = failed.get("tile:repeat", {})
    var stats: Dictionary = result.get("stats", {})
    _check(int(attempts.get("tile:repeat", 0)) == 2, "retry attempt history did not increment")
    _check(int(state.get("attempts", 0)) == 2, "failure state did not preserve second attempt")
    _check(int(state.get("retry_at_msec", -1)) == 2000, "second failure did not schedule exponential backoff")
    _check(str(state.get("category", "")) == "road", "failure category was not preserved")
    _check(int(stats.get("failures_recorded", 0)) == 2, "failure accounting lost repeated failure")
    _check(int(stats.get("active_failures", 0)) == 1, "repeated failure created duplicate active failures")

func _test_retry_timing_and_stale_cleanup() -> void:
    var scenario := {
        "schema_version": 1,
        "name": "timing-and-stale-cleanup",
        "actions": [
            {"op": "set_wanted", "keys": ["tile:a", "tile:b"]},
            {"op": "fail", "key": "tile:a"},
            {"op": "fail", "key": "tile:b"},
            {"op": "advance_ms", "value": 999},
            {"op": "release_due"},
            {"op": "advance_ms", "value": 1},
            {"op": "release_due"},
            {"op": "fail", "key": "tile:a"},
            {"op": "set_wanted", "keys": []},
            {"op": "forget_unwanted"},
        ],
    }
    var result := Harness.run_scenario(scenario)
    _check(bool(result.get("accepted", false)), "timing scenario rejected")
    _check((result.get("invariant_errors", []) as Array).is_empty(), "timing scenario violated invariants")
    var stats: Dictionary = result.get("stats", {})
    _check(int(stats.get("retries_released", 0)) == 2, "first retry deadline did not release both due failures")
    _check(int(stats.get("stale_failures_dropped", 0)) == 1, "unwanted active failure was not dropped")
    _check(int(stats.get("stale_attempts_dropped", 0)) == 1, "orphan retry-attempt history was not dropped")
    _check((result.get("failed", {}) as Dictionary).is_empty(), "stale cleanup left failed entries")
    _check((result.get("attempts", {}) as Dictionary).is_empty(), "stale cleanup left retry attempts")

func _test_legacy_failure_conversion() -> void:
    var scenario := {
        "schema_version": 1,
        "name": "legacy-failure-conversion",
        "actions": [
            {"op": "set_wanted", "keys": ["tile:legacy"]},
            {"op": "legacy_fail", "key": "tile:legacy"},
            {"op": "service"},
            {"op": "advance_ms", "value": 999},
            {"op": "service"},
            {"op": "advance_ms", "value": 1},
            {"op": "service"},
        ],
    }
    var result := Harness.run_scenario(scenario)
    _check(bool(result.get("accepted", false)), "legacy failure scenario rejected")
    _check((result.get("invariant_errors", []) as Array).is_empty(), "legacy conversion violated invariants")
    var trace: Array = result.get("trace", [])
    _check(trace.size() == 7, "legacy scenario trace length changed")
    if trace.size() == 7:
        _check((trace[2].get("failed", []) as Array).has("tile:legacy"), "legacy marker was not converted into retry state")
        _check((trace[4].get("failed", []) as Array).has("tile:legacy"), "legacy retry released before exact deadline")
        _check(not (trace[6].get("failed", []) as Array).has("tile:legacy"), "legacy retry did not release at deadline")
    var stats: Dictionary = result.get("stats", {})
    _check(int(stats.get("failures_recorded", 0)) == 1, "legacy conversion did not enter normal failure accounting")
    _check(int(stats.get("retries_released", 0)) == 1, "legacy converted retry did not release exactly once")

func _test_loaded_tile_clears_failure() -> void:
    var scenario := {
        "schema_version": 1,
        "name": "loaded-tile-cannot-remain-failed",
        "actions": [
            {"op": "set_wanted", "keys": ["tile:loaded"]},
            {"op": "fail", "key": "tile:loaded", "category": "building"},
            {"op": "load", "key": "tile:loaded"},
            {"op": "release_due"},
        ],
    }
    var result := Harness.run_scenario(scenario)
    _check(bool(result.get("accepted", false)), "loaded-tile scenario rejected")
    _check((result.get("invariant_errors", []) as Array).is_empty(),
        "loaded tile remained failed after recovery service: %s" % str(result.get("invariant_errors", [])))
    _check(not (result.get("failed", {}) as Dictionary).has("tile:loaded"),
        "loaded tile still exists in failed set")
    _check(not (result.get("attempts", {}) as Dictionary).has("tile:loaded"),
        "loaded tile still has retry attempts")
    var stats: Dictionary = result.get("stats", {})
    _check(int(stats.get("loaded_failures_cleared", 0)) == 1,
        "loaded failure reconciliation metric did not record the cleanup")

func _test_recovery_runtime_integration() -> void:
    var runtime := RecoveryRuntime.new()
    var streamer := FakeStreamer.new()
    root.add_child(runtime)
    root.add_child(streamer)
    streamer._wanted["tile:runtime"] = true
    streamer._failed["tile:runtime"] = true

    var first: Dictionary = runtime._service_streamer(streamer, "near-buildings", 0)
    _check(int(first.get("active_failures", 0)) == 1, "runtime did not convert initial legacy failure")
    _check(int(first.get("tracked_attempts", 0)) == 1, "runtime lost first retry attempt")
    _check(streamer.refresh_calls == 0, "runtime refreshed before retry deadline")

    runtime._service_streamer(streamer, "near-buildings", 999)
    _check(streamer.refresh_calls == 0, "runtime refreshed one millisecond before deadline")
    var released: Dictionary = runtime._service_streamer(streamer, "near-buildings", 1000)
    _check(streamer.refresh_calls == 1, "runtime did not force refresh when retry became due")
    _check(int(released.get("retries_released", 0)) == 1, "runtime retry release accounting mismatch")
    _check(is_equal_approx(streamer.last_refresh.x, 10.0) and is_equal_approx(streamer.last_refresh.y, 20.0),
        "runtime passed wrong world position into forced refresh")
    _check(is_equal_approx(streamer.last_refresh.z, 1.0), "runtime forced-refresh flag was lost")

    streamer._failed["tile:runtime"] = true
    runtime._service_streamer(streamer, "near-buildings", 1000)
    runtime._service_streamer(streamer, "near-buildings", 2999)
    _check(streamer.refresh_calls == 1, "second retry ignored exponential backoff")
    var second_release: Dictionary = runtime._service_streamer(streamer, "near-buildings", 3000)
    _check(streamer.refresh_calls == 2, "second retry did not release at its exponential deadline")
    _check(int(second_release.get("retries_released", 0)) == 2, "runtime lost cumulative retry-release accounting")

    streamer._failed["tile:runtime"] = true
    streamer._loaded["tile:runtime"] = true
    var loaded_cleanup: Dictionary = runtime._service_streamer(streamer, "near-buildings", 3000)
    _check(streamer.refresh_calls == 2, "already-loaded tile triggered redundant forced refresh")
    _check(not streamer._failed.has("tile:runtime"), "runtime left loaded tile in failed set")
    _check(int(loaded_cleanup.get("tracked_attempts", -1)) == 0, "runtime retained retry history for loaded tile")
    _check(int(loaded_cleanup.get("loaded_failures_cleared", 0)) == 1, "runtime did not report loaded failure reconciliation")

    streamer._loaded.clear()
    streamer._wanted.clear()
    streamer._failed["tile:runtime"] = true
    var stale_cleanup: Dictionary = runtime._service_streamer(streamer, "near-buildings", 3000)
    _check(streamer.refresh_calls == 2, "unwanted failure triggered forced refresh")
    _check(not streamer._failed.has("tile:runtime"), "runtime retained unwanted failure")
    _check(int(stale_cleanup.get("active_failures", -1)) == 0, "runtime stale cleanup left active failure accounting")

    streamer.queue_free()
    runtime.queue_free()
