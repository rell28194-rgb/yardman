extends SceneTree

const Vehicle = preload("res://scripts/vehicle_controller.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("VEHICLE_HANDLING_CONTRACT: " + message)

func _run() -> void:
    var low_lock := rad_to_deg(Vehicle.steering_limit_for_speed(0.0))
    var city_lock := rad_to_deg(Vehicle.steering_limit_for_speed(20.0))
    var highway_lock := rad_to_deg(Vehicle.steering_limit_for_speed(55.0))
    var vmax_lock := rad_to_deg(Vehicle.steering_limit_for_speed(Vehicle.MAX_FORWARD_MPS))
    _check(low_lock >= 37.5 and low_lock <= 38.5, "parking-speed steering lock must stay responsive")
    _check(city_lock < low_lock and highway_lock < city_lock and vmax_lock < highway_lock,
        "steering lock is not progressively reduced with speed")
    _check(vmax_lock >= 6.8 and vmax_lock <= 7.3, "Vmax steering lock is too large or too small")

    var half_input := absf(Vehicle.shaped_steering_input(0.5))
    _check(half_input >= 0.46 and half_input <= 0.50, "touch input is being over-damped")
    _check(absf(Vehicle.shaped_steering_input(1.0) - 1.0) < 0.001, "full steering input no longer reaches full command")
    _check(absf(Vehicle.shaped_steering_input(-0.5) + half_input) < 0.001, "steering shaping lost left/right symmetry")

    var low_apply := Vehicle.steering_response_rate(0.0, false)
    var high_apply := Vehicle.steering_response_rate(90.0, false)
    var high_return := Vehicle.steering_response_rate(90.0, true)
    _check(low_apply >= 10.4, "parking/city rack response is too slow")
    _check(high_apply >= 3.7 and high_apply <= 4.0, "high-speed rack response drifted")
    _check(high_return > high_apply * 1.8, "released high-speed steering does not return to centre decisively")
    _check(Vehicle.yaw_response_rate(90.0) < Vehicle.yaw_response_rate(0.0), "yaw response does not smooth with speed")

    var crown_turn_radius := Vehicle.minimum_turn_radius(2.85)
    _check(crown_turn_radius >= 3.3 and crown_turn_radius <= 3.8,
        "low-speed Crown turn radius is too wide: %.2fm" % crown_turn_radius)
    _check(Vehicle.ROAD_LATERAL_ACCEL >= 13.0, "road lateral authority is too weak")

    var road_grip := Vehicle.lateral_grip_response(45.0, true, false)
    var grass_grip := Vehicle.lateral_grip_response(45.0, false, false)
    var handbrake_grip := Vehicle.lateral_grip_response(45.0, true, true)
    _check(road_grip > grass_grip * 2.5, "road tyre response is not meaningfully stronger than off-road")
    _check(handbrake_grip < road_grip * 0.30, "handbrake no longer releases lateral grip")

    if failures == 0:
        print("YARDMAN_VEHICLE_HANDLING_CONTRACT_PASS low_lock=%.1f city_lock=%.1f highway_lock=%.1f vmax_lock=%.1f half_input=%.3f turn_radius=%.2f high_apply=%.1f high_return=%.1f" % [low_lock, city_lock, highway_lock, vmax_lock, half_input, crown_turn_radius, high_apply, high_return])
        quit(0)
        return
    print("YARDMAN_VEHICLE_HANDLING_CONTRACT_FAIL count=%d" % failures)
    quit(1)
