extends SceneTree

const Signals = preload("res://scripts/traffic_signal_runtime.gd")
const PlayerSignals = preload("res://scripts/vehicle_signal_runtime.gd")
var failures := 0

func _init() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("TRAFFIC_SIGNAL_TEST: " + message)

func _run() -> void:
    var north := Vector2(0.0, -1.0)
    var west := Vector2(-1.0, 0.0)
    var east := Vector2(1.0, 0.0)
    var slight := Vector2(0.20, -0.98).normalized()

    _check(Signals.turn_state(north, west) == PlayerSignals.SIGNAL_LEFT, "north-to-west continuation did not signal left")
    _check(Signals.turn_state(north, east) == PlayerSignals.SIGNAL_RIGHT, "north-to-east continuation did not signal right")
    _check(Signals.turn_state(north, north) == PlayerSignals.SIGNAL_OFF, "straight continuation incorrectly signaled")
    _check(Signals.turn_state(north, slight) == PlayerSignals.SIGNAL_OFF, "minor road bend incorrectly signaled as a turn")
    _check(Signals.turn_state(Vector2.ZERO, east) == PlayerSignals.SIGNAL_OFF, "invalid travel vector produced a signal")

    var south := Vector2(0.0, 1.0)
    _check(Signals.turn_state(south, east) == PlayerSignals.SIGNAL_LEFT, "southbound physical left-turn sign is reversed")
    _check(Signals.turn_state(south, west) == PlayerSignals.SIGNAL_RIGHT, "southbound physical right-turn sign is reversed")

    if failures == 0:
        print("YARDMAN_TRAFFIC_SIGNAL_TEST PASS left=1 right=1 straight=1 bend_filter=1 direction_invariant=1")
        quit()
    else:
        print("YARDMAN_TRAFFIC_SIGNAL_TEST FAIL failures=%d" % failures)
        quit(1)
