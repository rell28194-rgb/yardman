extends SceneTree

const Signals = preload("res://scripts/vehicle_signal_runtime.gd")
var failures := 0

func _init() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("VEHICLE_SIGNAL_TEST: " + message)

func _run() -> void:
    _check(Signals.next_state(Signals.SIGNAL_OFF, Signals.SIGNAL_LEFT) == Signals.SIGNAL_LEFT, "left signal did not activate")
    _check(Signals.next_state(Signals.SIGNAL_LEFT, Signals.SIGNAL_LEFT) == Signals.SIGNAL_OFF, "left signal did not toggle off")
    _check(Signals.next_state(Signals.SIGNAL_LEFT, Signals.SIGNAL_RIGHT) == Signals.SIGNAL_RIGHT, "right signal did not replace left")
    _check(Signals.next_state(Signals.SIGNAL_RIGHT, Signals.SIGNAL_HAZARD) == Signals.SIGNAL_HAZARD, "hazards did not override turn signal")

    _check(Signals.blink_on(0.0), "blink cycle should start illuminated")
    _check(not Signals.blink_on(Signals.BLINK_PERIOD_S * 0.75), "blink cycle off phase failed")
    _check(Signals.blink_on(Signals.BLINK_PERIOD_S * 1.05), "blink cycle did not wrap")

    _check(Signals.should_arm_cancel(0.14), "steering excursion did not arm auto-cancel")
    _check(not Signals.should_arm_cancel(0.04), "near-centre steering armed auto-cancel")
    _check(Signals.should_auto_cancel(0.02, 5.0), "steering return did not cancel moving signal")
    _check(not Signals.should_auto_cancel(0.02, 0.4), "parked steering return cancelled signal")

    var sedan := Signals.lamp_positions(Vector3(1.86, 1.45, 4.75))
    _check(Vector3(sedan.left_front).x < 0.0 and Vector3(sedan.right_front).x > 0.0, "indicator sides are reversed")
    _check(Vector3(sedan.left_front).z < 0.0 and Vector3(sedan.left_rear).z > 0.0, "front/rear indicator placement is reversed")
    _check(absf(Vector3(sedan.left_front).x) <= 0.96, "indicator exceeded bounded vehicle width placement")

    if failures == 0:
        print("YARDMAN_VEHICLE_SIGNAL_TEST PASS left_right=1 hazards=1 blink=1 auto_cancel=1 placement=1")
        quit()
    else:
        print("YARDMAN_VEHICLE_SIGNAL_TEST FAIL failures=%d" % failures)
        quit(1)
