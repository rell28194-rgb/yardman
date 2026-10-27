extends SceneTree

const PlayerScript = preload("res://scripts/player_controller.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("VEHICLE_INTERACTION_REGRESSION: " + message)

func _run() -> void:
    var dimensions := PlayerScript.dimensions_from_profile({"dimensions_m": [1.80, 1.46, 4.89]})
    _check(dimensions.is_equal_approx(Vector3(1.80, 1.46, 4.89)), "vehicle dimensions changed")

    var doors := PlayerScript.door_points_local(dimensions)
    _check(doors.size() == 4, "four door interaction points are required")
    _check(doors[0].z < 0.0 and doors[2].z > 0.0, "front/rear door zones collapsed")

    var exits := PlayerScript.exit_candidates_local(dimensions)
    _check(exits.size() == 8, "blocked-door fallback lost exit candidates")
    _check(absf(exits[0].x) > dimensions.x * 0.5, "exit candidate is inside vehicle width")
    _check(exits[4].z < exits[0].z and exits[6].z > exits[2].z, "front/rear escape fallbacks are missing")

    var near_door := doors[0] + Vector3(-0.7, 0.0, 0.0)
    _check(PlayerScript.nearest_door_distance(near_door, Transform3D.IDENTITY, dimensions) < 1.0, "near door distance rejected")
    _check(PlayerScript.nearest_door_distance(Vector3(9.0, 0.72, 9.0), Transform3D.IDENTITY, dimensions) > 5.0, "remote entry distance accepted")
    _check(PlayerScript.walkable_exit_normal(Vector3.UP, deg_to_rad(48.0)), "flat exit ground rejected")
    _check(not PlayerScript.walkable_exit_normal(Vector3(0.98, 0.20, 0.0).normalized(), deg_to_rad(48.0)), "unsafe steep exit accepted")
    _check(not PlayerScript.walkable_exit_normal(Vector3.ZERO, deg_to_rad(48.0)), "invalid exit normal accepted")

    var scene := Node3D.new()
    root.add_child(scene)
    var car := CharacterBody3D.new()
    scene.add_child(car)
    var vehicle_stub := {"body": car, "occupied": true, "speed_mps": 0.0}
    var player := PlayerScript.new()
    player.configure(vehicle_stub)
    scene.add_child(player)
    player._set_occupied(false)
    player.position = near_door
    _check(player.can_enter_vehicle(), "near stopped car cannot be entered")
    player.position = Vector3(8.0, 0.0, 0.0)
    _check(not player.can_enter_vehicle(), "distant stopped car can be entered")
    player._set_occupied(true)
    vehicle_stub.speed_mps = 4.0
    _check(not player.can_exit_vehicle(), "moving vehicle can be exited")
    vehicle_stub.speed_mps = 0.0
    _check(player.can_exit_vehicle(), "stopped vehicle cannot be exited")

    print("YARDMAN_VEHICLE_INTERACTION_REGRESSION %s doors=4 exits=8 distance=1 slope=1 moving_lockout=1" % ("PASS" if failures == 0 else "FAIL"))
    scene.queue_free()
    await process_frame
    quit(0 if failures == 0 else 1)
