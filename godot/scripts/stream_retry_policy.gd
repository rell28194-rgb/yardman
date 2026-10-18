extends RefCounted
class_name YardmanStreamRetryPolicy

const RETRY_BASE_MS := 1000
const RETRY_MAX_MS := 30000

static func retry_delay_ms(attempts: int) -> int:
    var exponent := clampi(attempts - 1, 0, 10)
    return mini(RETRY_MAX_MS, RETRY_BASE_MS * (1 << exponent))

static func record_failure(failed: Dictionary, attempts: Dictionary, key: String,
        stats: Dictionary, category: String = "stream", now_msec: int = -1) -> Dictionary:
    var now := Time.get_ticks_msec() if now_msec < 0 else now_msec
    var next_attempt := int(attempts.get(key, 0)) + 1
    attempts[key] = next_attempt
    var state := {
        "attempts": next_attempt,
        "retry_at_msec": now + retry_delay_ms(next_attempt),
        "category": category,
    }
    failed[key] = state
    stats["failures_recorded"] = int(stats.get("failures_recorded", 0)) + 1
    stats["active_failures"] = failed.size()
    return state

static func release_due(failed: Dictionary, attempts: Dictionary, loaded: Dictionary,
        stats: Dictionary, now_msec: int = -1) -> int:
    var now := Time.get_ticks_msec() if now_msec < 0 else now_msec
    for loaded_key in loaded.keys():
        attempts.erase(str(loaded_key))
    var released := 0
    for key_value in failed.keys():
        var state = failed[key_value]
        # Compatibility with older callers that stored a boolean failure marker.
        if not state is Dictionary:
            record_failure(failed, attempts, str(key_value), stats, "legacy", now)
            continue
        if now >= int((state as Dictionary).get("retry_at_msec", now)):
            failed.erase(key_value)
            released += 1
    if released > 0:
        stats["retries_released"] = int(stats.get("retries_released", 0)) + released
    stats["active_failures"] = failed.size()
    return released

static func forget_unwanted(failed: Dictionary, attempts: Dictionary, wanted: Dictionary,
        stats: Dictionary) -> int:
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
    stats["active_failures"] = failed.size()
    return dropped

static func snapshot(failed: Dictionary, attempts: Dictionary, stats: Dictionary) -> Dictionary:
    var result := stats.duplicate(true)
    result["active_failures"] = failed.size()
    result["tracked_attempts"] = attempts.size()
    result["retry_base_ms"] = RETRY_BASE_MS
    result["retry_max_ms"] = RETRY_MAX_MS
    return result
