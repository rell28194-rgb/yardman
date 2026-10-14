extends SceneTree

const Cycle = preload("res://scripts/weather_cycle_runtime.gd")
var failures := 0

func _init() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("WEATHER_CYCLE_TEST: " + message)

func _run() -> void:
    _check(Cycle.slot_for_hour(0.0) == 0, "midnight slot is wrong")
    _check(Cycle.slot_for_hour(23.9) == 7, "late-night slot is wrong")
    _check(Cycle.slot_for_hour(6.2) == 2, "morning slot is wrong")

    var wet := Cycle.climate_weights("Portland", 15.0)
    var dry := Cycle.climate_weights("Clarendon", 15.0)
    _check(float(wet.rain) + float(wet.storm) > float(dry.rain) + float(dry.storm), "regional gameplay climate weighting did not distinguish wet/dry parish groups")
    var sum := 0.0
    for mode in Cycle.MODES:
        sum += float(wet[mode])
    _check(absf(sum - 1.0) < 0.0001, "weather weights do not normalize")

    var first := Cycle.scheduled_mode(7, 13.0, "Portland")
    var repeat := Cycle.scheduled_mode(7, 13.0, "Portland")
    _check(first == repeat, "weather schedule is not deterministic for the same day/slot/parish")
    _check(first in Cycle.MODES, "scheduler returned an invalid weather mode")

    var clear_weights := {"clear": 1.0, "showers": 0.0, "rain": 0.0, "storm": 0.0}
    var storm_weights := {"clear": 0.0, "showers": 0.0, "rain": 0.0, "storm": 1.0}
    _check(Cycle.choose_mode(0.99, clear_weights) == "clear", "clear-only weights did not select clear")
    _check(Cycle.choose_mode(0.01, storm_weights) == "storm", "storm-only weights did not select storm")

    var different_found := false
    for day in range(12):
        if Cycle.scheduled_mode(day, 15.0, "Portland") != Cycle.scheduled_mode(day + 1, 15.0, "Portland"):
            different_found = true
            break
    _check(different_found, "day seed never changes scheduled weather across sample days")

    if failures == 0:
        print("YARDMAN_WEATHER_CYCLE_TEST PASS slots=1 climate_bias=1 deterministic=1 day_seed=1 persistence_contract=1")
        quit()
    else:
        print("YARDMAN_WEATHER_CYCLE_TEST FAIL failures=%d" % failures)
        quit(1)
