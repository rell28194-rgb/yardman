extends SceneTree

const Destinations = preload("res://scripts/pedestrian_destination_runtime.gd")
var failures := 0

func _init() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("PEDESTRIAN_DESTINATION_TEST: " + message)

func _run() -> void:
    var plan_a := Destinations.make_plan("ped-1", "road-1", 1, 0.25, 0)
    var plan_b := Destinations.make_plan("ped-1", "road-1", 1, 0.25, 0)
    _check(plan_a == plan_b, "same pedestrian objective was not deterministic")
    _check(int(plan_a.direction) == 1, "forward objective changed corridor direction")
    _check(float(plan_a.destination_progress) > 0.25, "forward destination was not ahead")

    var reverse := Destinations.make_plan("ped-2", "road-2", -1, 0.72, 0)
    _check(int(reverse.direction) == -1, "reverse objective changed corridor direction")
    _check(float(reverse.destination_progress) < 0.72, "reverse destination was not ahead in travel direction")

    var seam := Destinations.make_plan("ped-3", "road-3", 1, 0.91, 1)
    _check(float(seam.destination_progress) <= 1.08, "seam objective exceeded continuation guard")
    _check(float(seam.destination_progress) > 0.91, "near-seam objective reversed instead of handing off to road continuation")

    _check(Destinations.reached_destination(0.52, 0.50, 1), "forward overshoot did not register arrival")
    _check(Destinations.reached_destination(0.48, 0.50, -1), "reverse overshoot did not register arrival")
    _check(not Destinations.reached_destination(0.30, 0.50, 1), "pedestrian arrived before reaching objective")

    var dwell_a := Destinations.dwell_seconds("ped-1", 3)
    var dwell_b := Destinations.dwell_seconds("ped-1", 3)
    _check(is_equal_approx(dwell_a, dwell_b), "dwell time was not deterministic")
    _check(dwell_a >= 2.5 and dwell_a < 10.0, "dwell time escaped bounded activity window")

    var changed := false
    for sequence in range(1, 8):
        var next_plan := Destinations.make_plan("ped-1", "road-1", 1, 0.25, sequence)
        if not is_equal_approx(float(next_plan.destination_progress), float(plan_a.destination_progress)):
            changed = true
            break
    _check(changed, "successive pedestrian objectives never varied")

    if failures == 0:
        print("YARDMAN_PEDESTRIAN_DESTINATION_TEST PASS deterministic=1 directional=1 seam_handoff=1 dwell=1 objective_cycle=1")
        quit()
    else:
        print("YARDMAN_PEDESTRIAN_DESTINATION_TEST FAIL failures=%d" % failures)
        quit(1)
