extends SceneTree

const Harness = preload("res://scripts/streaming_adversarial_harness.gd")

const SEED_COUNT := 256
const RANDOM_ACTIONS := 96
const KEYS := ["tile:a", "tile:b", "tile:c", "tile:d", "tile:e", "tile:f"]
const CATEGORIES := ["road", "terrain", "building", "hlod"]

var failures := 0
var rng_state := 1

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("STREAM_RETRY_MODEL_TEST: " + message)

func _next_u32() -> int:
    rng_state = int((rng_state * 1664525 + 1013904223) & 0xffffffff)
    return rng_state

func _pick(array: Array):
    return array[_next_u32() % array.size()]

func _scenario_for_seed(seed: int) -> Dictionary:
    rng_state = seed
    var actions: Array = []
    for _index in range(RANDOM_ACTIONS):
        var op := _next_u32() % 9
        match op:
            0:
                var wanted: Array = []
                for key in KEYS:
                    if (_next_u32() & 1) == 1:
                        wanted.append(key)
                actions.append({"op": "set_wanted", "keys": wanted})
            1:
                actions.append({"op": "fail", "key": _pick(KEYS), "category": _pick(CATEGORIES)})
            2:
                actions.append({"op": "legacy_fail", "key": _pick(KEYS)})
            3:
                actions.append({"op": "load", "key": _pick(KEYS)})
            4:
                actions.append({"op": "unload", "key": _pick(KEYS)})
            5:
                actions.append({"op": "advance_ms", "value": int(_next_u32() % 40001)})
            6:
                actions.append({"op": "release_due"})
            7:
                actions.append({"op": "forget_unwanted"})
            8:
                actions.append({"op": "service"})
    # Finish in a reconciled state so stale loaded/failure combinations cannot
    # hide simply because the random trace ended between state transitions.
    actions.append({"op": "service"})
    return {"schema_version": 1, "name": "model-seed-%d" % seed, "actions": actions}

func _retry_delay(attempts: int) -> int:
    var exponent := clampi(attempts - 1, 0, 10)
    return mini(30000, 1000 * (1 << exponent))

func _record_failure(state: Dictionary, key: String, category: String) -> void:
    var attempts: Dictionary = state.attempts
    var failed: Dictionary = state.failed
    var stats: Dictionary = state.stats
    var next_attempt := int(attempts.get(key, 0)) + 1
    attempts[key] = next_attempt
    failed[key] = {
        "attempts": next_attempt,
        "retry_at_msec": int(state.now_msec) + _retry_delay(next_attempt),
        "category": category,
    }
    stats["failures_recorded"] = int(stats.get("failures_recorded", 0)) + 1
    stats["active_failures"] = failed.size()

func _release_due(state: Dictionary) -> void:
    var failed: Dictionary = state.failed
    var attempts: Dictionary = state.attempts
    var loaded: Dictionary = state.loaded
    var stats: Dictionary = state.stats
    var loaded_cleared := 0
    for loaded_key in loaded.keys():
        var key := str(loaded_key)
        attempts.erase(key)
        if failed.erase(key):
            loaded_cleared += 1
    if loaded_cleared > 0:
        stats["loaded_failures_cleared"] = int(stats.get("loaded_failures_cleared", 0)) + loaded_cleared

    var released := 0
    for key_value in failed.keys():
        var value = failed[key_value]
        if not value is Dictionary:
            _record_failure(state, str(key_value), "legacy")
            continue
        if int(state.now_msec) >= int((value as Dictionary).get("retry_at_msec", int(state.now_msec))):
            failed.erase(key_value)
            released += 1
    if released > 0:
        stats["retries_released"] = int(stats.get("retries_released", 0)) + released
    stats["active_failures"] = failed.size()

func _forget_unwanted(state: Dictionary) -> void:
    var failed: Dictionary = state.failed
    var attempts: Dictionary = state.attempts
    var wanted: Dictionary = state.wanted
    var stats: Dictionary = state.stats
    var dropped := 0
    for key_value in failed.keys():
        var key := str(key_value)
        if wanted.has(key):
            continue
        failed.erase(key_value)
        attempts.erase(key)
        dropped += 1
    if dropped > 0:
        stats["stale_failures_dropped"] = int(stats.get("stale_failures_dropped", 0)) + dropped

    var orphan_attempts_dropped := 0
    for key_value in attempts.keys():
        var key := str(key_value)
        if wanted.has(key):
            continue
        attempts.erase(key_value)
        orphan_attempts_dropped += 1
    if orphan_attempts_dropped > 0:
        stats["stale_attempts_dropped"] = int(stats.get("stale_attempts_dropped", 0)) + orphan_attempts_dropped
    stats["active_failures"] = failed.size()

func _reference(scenario: Dictionary) -> Dictionary:
    var state := {
        "failed": {},
        "attempts": {},
        "loaded": {},
        "wanted": {},
        "stats": {
            "failures_recorded": 0,
            "retries_released": 0,
            "stale_failures_dropped": 0,
            "active_failures": 0,
        },
        "now_msec": 0,
    }
    for action_value in scenario.actions:
        var action: Dictionary = action_value
        var op := str(action.op)
        match op:
            "set_wanted":
                var wanted: Dictionary = state.wanted
                wanted.clear()
                for key_value in action.keys:
                    wanted[str(key_value)] = true
            "fail":
                _record_failure(state, str(action.key), str(action.get("category", "stream")))
            "legacy_fail":
                var failed: Dictionary = state.failed
                failed[str(action.key)] = true
                var stats: Dictionary = state.stats
                stats["active_failures"] = failed.size()
            "load":
                var loaded: Dictionary = state.loaded
                loaded[str(action.key)] = true
            "unload":
                var loaded: Dictionary = state.loaded
                loaded.erase(str(action.key))
            "advance_ms":
                state.now_msec = int(state.now_msec) + int(action.value)
            "release_due":
                _release_due(state)
            "forget_unwanted":
                _forget_unwanted(state)
            "service":
                _forget_unwanted(state)
                _release_due(state)
    return state

func _compare(seed: int, actual: Dictionary, expected: Dictionary) -> void:
    _check(bool(actual.get("accepted", false)), "seed %d was rejected" % seed)
    _check((actual.get("invariant_errors", []) as Array).is_empty(),
        "seed %d violated invariant: %s" % [seed, str(actual.get("invariant_errors", []))])
    for field in ["failed", "attempts", "loaded", "wanted", "stats"]:
        _check(actual.get(field, {}) == expected.get(field, {}),
            "seed %d mismatch in %s actual=%s expected=%s" % [seed, field, str(actual.get(field, {})), str(expected.get(field, {}))])
    _check(int(actual.get("now_msec", -1)) == int(expected.now_msec),
        "seed %d clock mismatch" % seed)

func _run() -> void:
    for seed in range(1, SEED_COUNT + 1):
        var scenario := _scenario_for_seed(seed)
        var actual := Harness.run_scenario(scenario)
        var expected := _reference(scenario)
        _compare(seed, actual, expected)
    print("YARDMAN_STREAM_RETRY_MODEL_TEST %s seeds=%d random_actions=%d" % [
        "PASS" if failures == 0 else "FAIL", SEED_COUNT, RANDOM_ACTIONS])
    quit(0 if failures == 0 else 1)
