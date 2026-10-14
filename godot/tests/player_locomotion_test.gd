extends SceneTree

const PlayerScript = preload("res://scripts/player_controller.gd")
const TouchScript = preload("res://scripts/touch_controls.gd")
var failures := 0

func _init() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("PLAYER_LOCOMOTION_TEST: " + message)

func _run() -> void:
    _check(PlayerScript.locomotion_state_for(true, true, 0.0, false) == "vehicle", "vehicle state missing")
    _check(PlayerScript.locomotion_state_for(false, false, 4.0, true) == "airborne", "airborne state missing")
    _check(PlayerScript.locomotion_state_for(false, true, 0.0, false) == "idle", "idle state missing")
    _check(PlayerScript.locomotion_state_for(false, true, 2.0, false) == "walk", "walk state missing")
    _check(PlayerScript.locomotion_state_for(false, true, 7.0, true) == "sprint", "sprint state missing")

    var flat := PlayerScript.slope_tilt_for(Vector3.UP)
    _check(flat.length() < 0.0001, "flat ground should not tilt the visual rig")
    var steep := PlayerScript.slope_tilt_for(Vector3(0.62, 0.55, 0.56).normalized())
    _check(absf(steep.x) <= 0.14001 and absf(steep.y) <= 0.14001, "slope alignment exceeded production tilt clamp")

    var scene := Node.new()
    scene.name = "PlayerLocomotionTestScene"
    root.add_child(scene)
    current_scene = scene

    var touch := TouchScript.new()
    touch.name = "TouchControls"
    scene.add_child(touch)
    touch.driving = false

    var player := PlayerScript.new()
    player.name = "Player"
    scene.add_child(player)
    player._set_occupied(false)
    await process_frame
    await process_frame

    _check(player.get_node_or_null("LeftFootProbe") is RayCast3D, "left foot contact probe missing")
    _check(player.get_node_or_null("RightFootProbe") is RayCast3D, "right foot contact probe missing")
    _check((player.get_node("LeftFootProbe") as RayCast3D).enabled, "foot probes should be enabled on foot")
    _check(is_equal_approx(player.floor_snap_length, 0.6), "floor snap regression")
    _check(player.floor_stop_on_slope and player.floor_block_on_wall, "slope/wall locomotion policy missing")

    var jump_center: Vector2 = touch._center("jump")
    _check(touch._zone_at(jump_center) == "jump", "mobile JUMP control has no hit zone")
    touch._press(17, jump_center)
    _check(float(player.get("_jump_buffer")) > 0.0, "touch jump did not reach player jump buffer")
    _check(player.locomotion_state == "idle", "jump request should not fake an airborne state before physics")

    player._set_occupied(true)
    _check(not (player.get_node("LeftFootProbe") as RayCast3D).enabled, "foot probes should disable inside vehicle")
    player.request_jump()
    _check(is_zero_approx(float(player.get("_jump_buffer"))), "vehicle occupancy must reject jump requests")

    current_scene = null
    scene.queue_free()
    await process_frame
    if failures == 0:
        print("YARDMAN_PLAYER_LOCOMOTION_TEST PASS states=5 slopes=1 foot_probes=2 buffered_jump=1 mobile_jump=1")
        quit()
    else:
        print("YARDMAN_PLAYER_LOCOMOTION_TEST FAIL failures=%d" % failures)
        quit(1)
