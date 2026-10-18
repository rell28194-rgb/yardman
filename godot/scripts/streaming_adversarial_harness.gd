extends RefCounted
class_name YardmanStreamingAdversarialHarness

const RetryPolicy = preload("res://scripts/stream_retry_policy.gd")
const SCHEMA_VERSION := 1
const MAX_ACTIONS := 2048
const MAX_ADVANCE_MS := 3600000
const ALLOWED_OPS := {
    "set_wanted": true,
    "fail": true,
    "legacy_fail": true,
    "load": true,
    "unload": true,
    "advance_ms": true,
    "release_due": true,
    "forget_unwanted": true,
    "service": true,
}

static func run_scenario(scenario: Dictionary) -> Dictionary:
    var validation := validate_scenario(scenario)
    if not bool(validation.get("valid", false)):
        return {
            "accepted": false,
            "errors": validation.get("errors", []),
            "fingerprint": "rejected",
            "trace": [],
        }

    var failed: Dictionary = {}
    var attempts: Dictionary = {}
    var loaded: Dictionary = {}
    var wanted: Dictionary = {}
    var stats: Dictionary = {
        "failures_recorded": 0,
        "retries_released": 0,
        "stale_failures_dropped": 0,
        "active_failures": 0,
    }
    var now_msec := 0
    var trace: Array = []
    var invariant_errors: Array[String] = []
    var actions: Array = scenario.get("actions", [])

    for index in range(actions.size()):
        var action: Dictionary = actions[index]
        var op := str(action.get("op", ""))
        match op:
            "set_wanted":
                wanted.clear()
                for key_value in action.get("keys", []):
                    wanted[str(key_value)] = true
            "fail":
                var key := str(action.get("key", ""))
                RetryPolicy.record_failure(failed, attempts, key, stats,
                    str(action.get("category", "stream")), now_msec)
            "legacy_fail":
                failed[str(action.get("key", ""))] = true
                stats["active_failures"] = failed.size()
            "load":
                loaded[str(action.get("key", ""))] = true
            "unload":
                loaded.erase(str(action.get("key", "")))
            "advance_ms":
                now_msec += int(action.get("value", 0))
            "release_due":
                RetryPolicy.release_due(failed, attempts, loaded, stats, now_msec)
            "forget_unwanted":
                RetryPolicy.forget_unwanted(failed, attempts, wanted, stats)
            "service":
                RetryPolicy.forget_unwanted(failed, attempts, wanted, stats)
                RetryPolicy.release_due(failed, attempts, loaded, stats, now_msec)

        var require_reconciled := op in ["release_due", "service"]
        var step_errors := _invariant_errors(failed, attempts, loaded, stats, require_reconciled)
        for message in step_errors:
            invariant_errors.append("step %d (%s): %s" % [index, op, message])
        trace.append(_snapshot(index, op, now_msec, failed, attempts, loaded, wanted, stats))

    return {
        "accepted": true,
        "name": str(scenario.get("name", "unnamed")),
        "invariant_errors": invariant_errors,
        "failed": failed.duplicate(true),
        "attempts": attempts.duplicate(true),
        "loaded": loaded.duplicate(true),
        "wanted": wanted.duplicate(true),
        "stats": stats.duplicate(true),
        "now_msec": now_msec,
        "trace": trace,
        "fingerprint": _fingerprint(now_msec, failed, attempts, loaded, wanted, stats),
    }

static func validate_scenario(scenario: Dictionary) -> Dictionary:
    var errors: Array[String] = []
    if int(scenario.get("schema_version", -1)) != SCHEMA_VERSION:
        errors.append("unsupported schema_version")
    var actions_value = scenario.get("actions", null)
    if not actions_value is Array:
        errors.append("actions must be an Array")
        return {"valid": false, "errors": errors}
    var actions: Array = actions_value
    if actions.size() > MAX_ACTIONS:
        errors.append("action count exceeds safety limit")
    for index in range(actions.size()):
        var value = actions[index]
        if not value is Dictionary:
            errors.append("action %d must be a Dictionary" % index)
            continue
        var action: Dictionary = value
        var op := str(action.get("op", ""))
        if not ALLOWED_OPS.has(op):
            errors.append("action %d has unsupported op '%s'" % [index, op])
            continue
        if op in ["fail", "legacy_fail", "load", "unload"]:
            if str(action.get("key", "")).strip_edges().is_empty():
                errors.append("action %d requires non-empty key" % index)
        elif op == "set_wanted":
            if not action.get("keys", null) is Array:
                errors.append("action %d set_wanted requires keys Array" % index)
            else:
                for key_value in action.get("keys", []):
                    if str(key_value).strip_edges().is_empty():
                        errors.append("action %d contains empty wanted key" % index)
        elif op == "advance_ms":
            var amount = action.get("value", null)
            if not (amount is int or amount is float):
                errors.append("action %d advance_ms requires numeric value" % index)
            else:
                var millis := int(amount)
                if millis < 0 or millis > MAX_ADVANCE_MS:
                    errors.append("action %d advance_ms outside safety bounds" % index)
    return {"valid": errors.is_empty(), "errors": errors}

static func _invariant_errors(failed: Dictionary, attempts: Dictionary,
        loaded: Dictionary, stats: Dictionary, require_reconciled: bool) -> Array[String]:
    var errors: Array[String] = []
    if int(stats.get("active_failures", -1)) != failed.size():
        errors.append("active_failures diverged from failed set")
    for key_value in attempts.keys():
        var attempt_count := int(attempts[key_value])
        if attempt_count < 1:
            errors.append("attempt count fell below one for %s" % str(key_value))
    for key_value in failed.keys():
        var key := str(key_value)
        if key.strip_edges().is_empty():
            errors.append("empty failure key")
        var state = failed[key_value]
        if state is Dictionary:
            var state_dict: Dictionary = state
            var state_attempts := int(state_dict.get("attempts", 0))
            if state_attempts < 1:
                errors.append("failure state has invalid attempts for %s" % key)
            var delay := int(state_dict.get("retry_at_msec", 0))
            if delay < 0:
                errors.append("failure state has negative retry time for %s" % key)
    if require_reconciled:
        for loaded_key in loaded.keys():
            var key := str(loaded_key)
            if failed.has(key):
                errors.append("loaded tile remains marked failed after policy service: %s" % key)
    for counter in ["failures_recorded", "retries_released", "stale_failures_dropped", "active_failures"]:
        if int(stats.get(counter, 0)) < 0:
            errors.append("negative stats counter: %s" % counter)
    return errors

static func _snapshot(index: int, op: String, now_msec: int, failed: Dictionary,
        attempts: Dictionary, loaded: Dictionary, wanted: Dictionary,
        stats: Dictionary) -> Dictionary:
    return {
        "index": index,
        "op": op,
        "now_msec": now_msec,
        "failed": _sorted_keys(failed),
        "attempts": _sorted_attempts(attempts),
        "loaded": _sorted_keys(loaded),
        "wanted": _sorted_keys(wanted),
        "active_failures": int(stats.get("active_failures", 0)),
        "retries_released": int(stats.get("retries_released", 0)),
        "stale_failures_dropped": int(stats.get("stale_failures_dropped", 0)),
    }

static func _fingerprint(now_msec: int, failed: Dictionary, attempts: Dictionary,
        loaded: Dictionary, wanted: Dictionary, stats: Dictionary) -> String:
    var parts := PackedStringArray()
    parts.append("t=%d" % now_msec)
    parts.append("failed=" + ",".join(_sorted_keys(failed)))
    parts.append("attempts=" + ",".join(_sorted_attempts(attempts)))
    parts.append("loaded=" + ",".join(_sorted_keys(loaded)))
    parts.append("wanted=" + ",".join(_sorted_keys(wanted)))
    parts.append("fr=%d" % int(stats.get("failures_recorded", 0)))
    parts.append("rr=%d" % int(stats.get("retries_released", 0)))
    parts.append("sd=%d" % int(stats.get("stale_failures_dropped", 0)))
    parts.append("af=%d" % int(stats.get("active_failures", 0)))
    return "|".join(parts)

static func _sorted_keys(values: Dictionary) -> Array[String]:
    var result: Array[String] = []
    for key_value in values.keys():
        result.append(str(key_value))
    result.sort()
    return result

static func _sorted_attempts(values: Dictionary) -> Array[String]:
    var result: Array[String] = []
    for key_value in values.keys():
        result.append("%s:%d" % [str(key_value), int(values[key_value])])
    result.sort()
    return result
