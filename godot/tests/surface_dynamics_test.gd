extends SceneTree

const Catalog = preload("res://scripts/vehicle_catalog.gd")
const Dynamics = preload("res://scripts/surface_dynamics_runtime.gd")

var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("SURFACE_DYNAMICS_TEST: " + message)

func _run() -> void:
    for vehicle_id in Catalog.production_ids():
        var dry := Catalog.profile(vehicle_id)
        var dry_adjusted := Dynamics.adjusted_profile(vehicle_id, 0.0, true)
        var wet_low_speed := Dynamics.adjusted_profile(vehicle_id, 1.0, true, 10.0)
        var wet_high_speed := Dynamics.adjusted_profile(vehicle_id, 1.0, true, 42.0)
        var wet_repeat := Dynamics.adjusted_profile(vehicle_id, 1.0, true, 42.0)
        var wet_offroad_low := Dynamics.adjusted_profile(vehicle_id, 1.0, false, 10.0)
        var wet_offroad_high := Dynamics.adjusted_profile(vehicle_id, 1.0, false, 32.0)

        _check(is_equal_approx(float(dry_adjusted.brake_decel_mps2), float(dry.brake_decel_mps2)), "%s dry braking changed" % vehicle_id)
        _check(is_equal_approx(float(dry_adjusted.grip_accel_mps2), float(dry.grip_accel_mps2)), "%s dry grip changed" % vehicle_id)
        _check(float(wet_low_speed.brake_decel_mps2) < float(dry.brake_decel_mps2), "%s wet asphalt did not lengthen braking" % vehicle_id)
        _check(float(wet_low_speed.grip_accel_mps2) < float(dry.grip_accel_mps2), "%s wet asphalt did not reduce lateral grip" % vehicle_id)
        _check(float(wet_low_speed.lateral_response) < float(dry.lateral_response), "%s wet asphalt did not slow lateral recovery" % vehicle_id)
        _check(float(wet_high_speed.brake_decel_mps2) < float(wet_low_speed.brake_decel_mps2), "%s high-speed rain did not reduce braking reserve further" % vehicle_id)
        _check(float(wet_high_speed.grip_accel_mps2) < float(wet_low_speed.grip_accel_mps2), "%s high-speed rain did not reduce lateral grip further" % vehicle_id)
        _check(float(wet_high_speed.lateral_response) < float(wet_low_speed.lateral_response), "%s high-speed rain did not reduce recovery response" % vehicle_id)
        _check(float(wet_high_speed.yaw_cap) < float(wet_low_speed.yaw_cap), "%s high-speed rain did not taper yaw authority" % vehicle_id)
        _check(is_equal_approx(float(wet_high_speed.max_forward_mps), float(dry.max_forward_mps)), "%s rain changed governed top speed" % vehicle_id)
        _check(is_equal_approx(float(wet_repeat.brake_decel_mps2), float(wet_high_speed.brake_decel_mps2)), "%s wet profile accumulated multipliers" % vehicle_id)
        _check(float(wet_offroad_low.offroad_grip_accel_mps2) < float(dry.offroad_grip_accel_mps2), "%s wet offroad grip did not reduce" % vehicle_id)
        _check(float(wet_offroad_low.offroad_drag_base) > float(dry.offroad_drag_base), "%s wet offroad drag did not rise" % vehicle_id)
        _check(float(wet_offroad_low.grass_limit_mps) < float(dry.grass_limit_mps), "%s wet grass limit did not fall" % vehicle_id)
        _check(float(wet_offroad_high.offroad_grip_accel_mps2) < float(wet_offroad_low.offroad_grip_accel_mps2), "%s wet offroad high-speed grip did not degrade further" % vehicle_id)
        _check(float(wet_offroad_high.offroad_drag_base) > float(wet_offroad_low.offroad_drag_base), "%s wet offroad high-speed drag did not rise further" % vehicle_id)
        _check(str(wet_high_speed.audio_profile) == str(dry.audio_profile), "%s surface dynamics corrupted identity metadata" % vehicle_id)

    print("YARDMAN_SURFACE_DYNAMICS_TEST %s vehicles=%d wet_asphalt=1 speed_sensitive_wet=1 wet_offroad=1" % ["PASS" if failures == 0 else "FAIL", Catalog.production_ids().size()])
    quit(0 if failures == 0 else 1)
