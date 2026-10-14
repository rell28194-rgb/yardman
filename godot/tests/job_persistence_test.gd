extends SceneTree

const Persistence = preload("res://scripts/job_persistence_runtime.gd")
var failures := 0

func _init() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("JOB_PERSISTENCE_TEST: " + message)

func _run() -> void:
    var state := {"wallet_jmd": 8750, "offer_sequence": 4, "active_job": {}}
    _check(Persistence.valid_state(state), "valid empty-contract economy state was rejected")
    var wrapped := Persistence.wrap_state(state)
    _check(not wrapped.is_empty(), "valid state did not produce checksum wrapper")
    var decoded := Persistence.unwrap_state(wrapped)
    _check(int(decoded.get("wallet_jmd", -1)) == 8750 and int(decoded.get("offer_sequence", -1)) == 4, "wrapped economy state did not round-trip")

    var tampered := wrapped.duplicate(true)
    tampered["payload_json"] = str(tampered.get("payload_json", "")) + " "
    _check(Persistence.unwrap_state(tampered).is_empty(), "tampered payload bypassed checksum")

    var invalid := state.duplicate(true)
    invalid["wallet_jmd"] = -1
    _check(not Persistence.valid_state(invalid), "negative wallet was accepted")
    invalid = state.duplicate(true)
    invalid["offer_sequence"] = INF
    _check(not Persistence.valid_state(invalid), "non-finite offer sequence was accepted")

    var active := state.duplicate(true)
    active["active_job"] = {"origin_parish": "St. Mary", "destination_parish": "Portland", "destination_x": 1000.0, "destination_z": 2000.0, "reward_jmd": 4200, "required_travel_m": 900.0, "travelled_m": 450.0}
    _check(Persistence.valid_state(active), "valid active contract state was rejected")

    if failures == 0:
        print("YARDMAN_JOB_PERSISTENCE_TEST PASS valid=2 checksum=2 invalid=2 active=1")
        quit()
    else:
        print("YARDMAN_JOB_PERSISTENCE_TEST FAIL failures=%d" % failures)
        quit(1)
