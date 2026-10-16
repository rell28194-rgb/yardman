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

    var crown_dims := PlayerScript.dimensions_from_profile({"dimensions_m": [1.80, 1.46, 4.89]})
    var mark_dims := PlayerScript.dimensions_from_profile({"dimensions_m": [1.79, 1.44, 4.77]})
    var sports_dims := PlayerScript.dimensions_from_profile({"dimensions_m": [1.85, 1.30, 4.54]})
    _check(crown_dims.is_equal_approx(Vector3(1.80, 1.46, 4.89)), "Crown dimensions were not preserved for interaction geometry")
    _check(mark_dims.is_equal_approx(Vector3(1.79, 1.44, 4.77)), "Mark X dimensions were not preserved for interaction geometry")
    _check(sports_dims.is_equal_approx(Vector3(1.85, 1.30, 4.54)), "992-class dimensions were not preserved for interaction geometry")

    var crown_doors := PlayerScript.door_points_local(crown_dims)
    _check(crown_doors.size() == 4, "production vehicle should expose four interaction door points")
    _check(is_equal_approx(absf(crown_doors[0].x), crown_dims.x * 0.5), "door point does not follow vehicle width")
    _check(crown_doors[0].z < 0.0 and crown_doors[2].z > 0.0, "front/rear door zones are not separated")

    var exits := PlayerScript.exit_candidates_local(crown_dims)
    _check(exits.size() == 8, "blocked-door fallback needs eight profile-aware exit candidates")
    _check(absf(exits[0].x) > crown_dims.x * 0.5, "exit candidate is still inside vehicle width")
    _check(exits[4].z < exits[0].z and exits[6].z > exits[2].z, "front/rear escape fallbacks are missing")

    var identity := Transform3D.IDENTITY
    var near_left_front := identity * crown_doors[0] + Vector3(-0.8, 0.0, 0.0)
    var far_away := Vector3(9.0, 0.72, 9.0)
    _check(PlayerScript.nearest_door_distance(near_left_front, identity, crown_dims) < 1.0, "door-aware entry distance rejected a nearby player")
    _check(PlayerScript.nearest_door_distance(far_away, identity, crown_dims) > 5.0, "door-aware entry distance accepted a remote player")
    _check(PlayerScript.walkable_exit_normal(Vector3.UP, deg_to_rad(48.0)), "flat exit ground should be walkable")
    _check(not PlayerScript.walkable_exit_normal(Vector3(0.98, 0.20, 0.0).normalized(), deg_to_rad(48.0)), "unsafe steep exit ground was accepted")
    _check(not PlayerScript.walkable_exit_normal(Vector3.ZERO, deg_to_rad(48.0)), "invalid exit normal was accepted")

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
        print("YARDMAN_PLAYER_LOCOMOTION_TEST PASS states=5 slopes=1 foot_probes=2 buffered_jump=1 mobile_jump=1 door_geometry=3 exit_candidates=8 slope_exit=1")
        quit()
    else:
        print("YARDMAN_PLAYER_LOCOMOTION_TEST FAIL failures=%d" % failures)
        quit(1)
