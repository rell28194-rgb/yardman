extends SceneTree

const Jobs = preload("res://scripts/job_runtime.gd")
var failures := 0

func _init() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("JOB_RUNTIME_TEST: " + message)

func _run() -> void:
    var anchor := {"road_position": [1234.0, 18.0, 5678.0]}
    _check(Jobs.anchor_xz(anchor).distance_to(Vector2(1234.0, 5678.0)) < 0.001, "road anchor extraction failed")

    _check(Jobs.reward_for_distance(100000.0) > Jobs.reward_for_distance(10000.0), "longer jobs should pay more")
    _check(Jobs.reward_for_contract(40000.0, Jobs.CONTRACT_EXPRESS) > Jobs.reward_for_contract(40000.0, Jobs.CONTRACT_STANDARD), "express contract should pay more than standard")
    _check(Jobs.required_travel_for_distance(100000.0) > Jobs.required_travel_for_distance(10000.0), "longer jobs should require more actual driving")
    _check(Jobs.required_travel_for_distance(100.0) >= 650.0, "short jobs lost the anti-fast-travel minimum")
    _check(Jobs.express_deadline_for_distance(100000.0) > Jobs.express_deadline_for_distance(10000.0), "express deadline did not scale with distance")
    _check(Jobs.express_deadline_for_distance(100.0) >= 300.0, "express minimum deadline disappeared")

    _check(absf(Jobs.eligible_travel_step(Vector2.ZERO, Vector2(20.0, 0.0)) - 20.0) < 0.001, "normal canonical movement was not counted")
    _check(Jobs.eligible_travel_step(Vector2.ZERO, Vector2(1000.0, 0.0)) == 0.0, "teleport-sized movement was counted as job travel")

    _check(Jobs.completion_ready(40.0, 0.2, true, 1500.0, 1000.0), "valid stopped delivery did not complete")
    _check(not Jobs.completion_ready(40.0, 8.0, true, 1500.0, 1000.0), "moving delivery completed")
    _check(not Jobs.completion_ready(40.0, 0.2, false, 1500.0, 1000.0), "on-foot delivery completed")
    _check(not Jobs.completion_ready(40.0, 0.2, true, 500.0, 1000.0), "fast-travel delivery completed without required driving")
    _check(not Jobs.completion_ready(140.0, 0.2, true, 1500.0, 1000.0), "delivery completed outside arrival radius")

    var parishes := ["Kingston", "St. Andrew", "St. Catherine", "Clarendon", "Manchester", "St. Elizabeth", "Westmoreland", "Hanover", "St. James", "Trelawny", "St. Ann", "St. Mary", "Portland", "St. Thomas"]
    var offers_a := Jobs.offer_destinations(parishes, "St. Mary", 3)
    var offers_b := Jobs.offer_destinations(parishes, "St. Mary", 3)
    _check(offers_a == offers_b, "offer generation is not deterministic")
    _check(offers_a.size() == 3, "courier board should expose three destinations")
    _check(not offers_a.has("St. Mary"), "courier board offered same-parish destination")
    var unique: Dictionary = {}
    for destination in offers_a:
        unique[destination] = true
    _check(unique.size() == offers_a.size(), "courier board returned duplicate destinations")
    var express_slot_a := Jobs.express_slot_for("St. Mary", 3, offers_a.size())
    var express_slot_b := Jobs.express_slot_for("St. Mary", 3, offers_a.size())
    _check(express_slot_a == express_slot_b and express_slot_a >= 0 and express_slot_a < offers_a.size(), "express board slot is not deterministic/in-range")

    _check(Jobs.format_time(65.0) == "01:05", "short express timer formatting failed")
    _check(Jobs.format_time(3661.0) == "1:01:01", "hour express timer formatting failed")

    var valid_job := {"origin_parish": "St. Mary", "destination_parish": "St. James", "destination_x": 1.0, "destination_z": 2.0, "reward_jmd": 5000, "required_travel_m": 1000.0, "travelled_m": 500.0}
    _check(Jobs._valid_persisted_job(valid_job), "legacy standard persisted job was rejected")
    var express_job := valid_job.duplicate(true)
    express_job["contract_type"] = Jobs.CONTRACT_EXPRESS
    express_job["deadline_s"] = 900.0
    express_job["time_remaining_s"] = 450.0
    _check(Jobs._valid_persisted_job(express_job), "valid express persisted job was rejected")
    var invalid_job := valid_job.duplicate(true)
    invalid_job["destination_x"] = INF
    _check(not Jobs._valid_persisted_job(invalid_job), "non-finite persisted job was accepted")
    var broken_express := express_job.duplicate(true)
    broken_express.erase("time_remaining_s")
    _check(not Jobs._valid_persisted_job(broken_express), "express job without timer state was accepted")
    var unknown_type := valid_job.duplicate(true)
    unknown_type["contract_type"] = "mystery"
    _check(not Jobs._valid_persisted_job(unknown_type), "unknown contract type was accepted")

    if failures == 0:
        print("YARDMAN_JOB_RUNTIME_TEST PASS anchors=1 economy=5 travel_guard=2 completion=5 offers=5 timers=2 persistence=5")
        quit()
    else:
        print("YARDMAN_JOB_RUNTIME_TEST FAIL failures=%d" % failures)
        quit(1)
