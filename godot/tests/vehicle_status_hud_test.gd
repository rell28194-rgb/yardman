extends SceneTree

const StatusScript = preload("res://scripts/vehicle_status_hud_runtime.gd")
var failures := 0

class FakeVehicle extends RefCounted:
    var odometer_m := 12345.0
    var occupied := true
    var speed_mps := 0.0
    func gear_label() -> String:
        return "D2" if occupied else "P"

class FakePlayer extends Node:
    var in_vehicle := true

class FakeGame extends Node:
    var vehicle = FakeVehicle.new()
    var player = FakePlayer.new()

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("VEHICLE_STATUS_HUD_TEST: " + message)

func _initialize() -> void:
    call_deferred("_run")

func _run() -> void:
    var game := FakeGame.new()
    root.add_child(game)
    current_scene = game

    var driving_text := StatusScript.status_text_for(game)
    _check(driving_text.contains("D2"), "driving gear is not visible")
    _check(driving_text.contains("ODO 12.3 km"), "odometer is not visible while driving")

    game.player.in_vehicle = false
    game.vehicle.occupied = false
    var parked_text := StatusScript.status_text_for(game)
    _check(parked_text.contains("PARKED"), "parked state disappears after exit")
    _check(parked_text.contains("ODO 12.3 km"), "odometer disappears after exit")

    var runtime := StatusScript.new()
    root.add_child(runtime)
    await process_frame
    await process_frame
    _check(runtime.debug_text() == parked_text, "runtime label does not match parked state")

    print("YARDMAN_VEHICLE_STATUS_HUD_TEST %s driving_odo=1 parked=1 parked_odo=1" % ("PASS" if failures == 0 else "FAIL"))
    current_scene = null
    runtime.queue_free()
    game.queue_free()
    await process_frame
    quit(0 if failures == 0 else 1)
