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

    # National streaming can free an agent body or its signal child before the
    # runtime's next 160 ms update. Reproduce both stale-reference paths so the
    # regression catches the exact `is`-on-freed-instance failure seen in CI.
    var runtime := Signals.new()
    runtime.set_process(false)
    root.add_child(runtime)
    var body := Node3D.new()
    root.add_child(body)

    var first_rig: Dictionary = runtime._ensure_rig("stale-remove", body)
    var first_root = first_rig.get("root", null)
    _check(is_instance_valid(first_root), "fixture failed to create first signal rig")
    if is_instance_valid(first_root):
        first_root.free()
    _check(not is_instance_valid(first_root), "fixture failed to produce a freed rig reference")
    runtime._remove_rig("stale-remove")
    _check(int(runtime.runtime_snapshot().get("signal_rigs", -1)) == 0, "stale rig removal left cached state")

    var second_rig: Dictionary = runtime._ensure_rig("stale-recreate", body)
    var second_root = second_rig.get("root", null)
    _check(is_instance_valid(second_root), "fixture failed to create second signal rig")
    var second_id := 0
    if is_instance_valid(second_root):
        second_id = second_root.get_instance_id()
        second_root.free()
    var replacement: Dictionary = runtime._ensure_rig("stale-recreate", body)
    var replacement_root = replacement.get("root", null)
    _check(is_instance_valid(replacement_root), "freed cached rig was not recreated")
    if is_instance_valid(replacement_root):
        _check(replacement_root.get_instance_id() != second_id, "stale rig cache returned the freed instance")

    var stale_body := Node3D.new()
    root.add_child(stale_body)
    stale_body.free()
    _check(not Signals._is_live_node3d(stale_body), "freed traffic body was reported as live")

    runtime._clear_all()
    if is_instance_valid(body):
        body.queue_free()
    runtime.queue_free()
    await process_frame

    if failures == 0:
        print("YARDMAN_TRAFFIC_SIGNAL_TEST PASS left=1 right=1 straight=1 bend_filter=1 direction_invariant=1 freed_rig=1 freed_body=1")
        quit()
    else:
        print("YARDMAN_TRAFFIC_SIGNAL_TEST FAIL failures=%d" % failures)
        quit(1)
