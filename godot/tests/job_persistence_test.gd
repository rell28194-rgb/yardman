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
    _check(Persistence.valid_state(active), "valid active standard contract state was rejected")

    var express := state.duplicate(true)
    express["active_job"] = {"origin_parish": "St. Mary", "destination_parish": "St. James", "destination_x": 3000.0, "destination_z": 4000.0, "reward_jmd": 6500, "required_travel_m": 1200.0, "travelled_m": 600.0, "contract_type": "express", "deadline_s": 1200.0, "time_remaining_s": 733.5}
    _check(Persistence.valid_state(express), "valid active express contract state was rejected")
    var express_roundtrip := Persistence.unwrap_state(Persistence.wrap_state(express))
    var restored_job = express_roundtrip.get("active_job", {})
    _check(restored_job is Dictionary and absf(float(restored_job.get("time_remaining_s", -1.0)) - 733.5) < 0.001, "express countdown state did not round-trip")

    var broken_express := express.duplicate(true)
    (broken_express["active_job"] as Dictionary).erase("time_remaining_s")
    _check(not Persistence.valid_state(broken_express), "broken express countdown state was accepted")

    if failures == 0:
        print("YARDMAN_JOB_PERSISTENCE_TEST PASS valid=3 checksum=3 invalid=3 express=2")
        quit()
    else:
        print("YARDMAN_JOB_PERSISTENCE_TEST FAIL failures=%d" % failures)
        quit(1)
