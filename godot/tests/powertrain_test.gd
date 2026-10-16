extends SceneTree

const Catalog = preload("res://scripts/vehicle_catalog.gd")
const Powertrain = preload("res://scripts/vehicle_powertrain.gd")
const Controller = preload("res://scripts/vehicle_controller.gd")

var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("POWERTRAIN_TEST: " + message)

func _run() -> void:
    for vehicle_id in Catalog.production_ids():
        var data := Catalog.profile(vehicle_id)
        for field in ["transmission", "peak_torque_nm", "gear_ratios", "final_drive", "reverse_ratio", "torque_curve", "shift_up_rpm", "shift_down_rpm", "shift_time_s"]:
            _check(data.has(field), "%s missing powertrain field %s" % [vehicle_id, field])
        _check(Powertrain.gear_count(data) >= 6, "%s does not expose a production transmission gear set" % vehicle_id)
        _check(float(data.final_drive) > 2.0, "%s final drive is not active data" % vehicle_id)
        _check((data.torque_curve as Array).size() >= 5, "%s torque curve is underspecified" % vehicle_id)

        var first_rpm := Powertrain.driveline_rpm(data, 14.0, 0)
        var second_rpm := Powertrain.driveline_rpm(data, 14.0, 1)
        _check(first_rpm > second_rpm, "%s higher gear did not lower RPM at equal road speed" % vehicle_id)
        _check(Powertrain.target_rpm(data, 0.0, 0, 1.0) > float(data.idle_rpm), "%s launch throttle did not free-rev engine" % vehicle_id)
        _check(Powertrain.torque_factor(data, float(data.redline_rpm)) < 1.05, "%s torque curve never falls near redline" % vehicle_id)

        var forced_up := Powertrain.select_gear(data, 18.0, 0, 1.0, float(data.shift_up_rpm) + 50.0)
        _check(forced_up == 1, "%s full-load upshift threshold did not select second gear" % vehicle_id)

        var launch_accel := Powertrain.drive_acceleration(data, float(data.idle_rpm) + 2200.0, 0, 4.0, 1.0)
        var tall_accel := Powertrain.drive_acceleration(data, float(data.idle_rpm) + 2200.0, Powertrain.gear_count(data) - 1, 4.0, 1.0)
        _check(launch_accel > tall_accel, "%s gearing has no influence on wheel acceleration" % vehicle_id)

        var shorter := data.duplicate(true)
        shorter.final_drive = float(data.final_drive) * 1.12
        var shorter_accel := Powertrain.drive_acceleration(shorter, float(data.idle_rpm) + 2200.0, 0, 4.0, 1.0)
        _check(shorter_accel > launch_accel, "%s final drive does not influence acceleration" % vehicle_id)

    var crown := Catalog.profile("toyota_crown")
    var sports := Catalog.profile("port_royal_992")
    var crown_launch := Powertrain.drive_acceleration(crown, 3600.0, 0, 4.0, 1.0)
    var sports_launch := Powertrain.drive_acceleration(sports, 4200.0, 0, 4.0, 1.0)
    _check(sports_launch > crown_launch, "sports and Crown launch character collapsed to identical output")
    _check(float(sports.shift_time_s) < float(crown.shift_time_s), "dual-clutch profile is not shifting faster than Crown automatic")

    var scene := Node3D.new()
    root.add_child(scene)
    var car := CharacterBody3D.new()
    var collider := CollisionShape3D.new()
    var shape := BoxShape3D.new()
    shape.size = Vector3(1.85, 1.30, 4.0)
    collider.shape = shape
    car.add_child(collider)
    scene.add_child(car)
    var controller = Controller.new()
    controller.configure(car, "toyota_mark_x")
    var snapshot := controller.transmission_snapshot()
    _check(str(snapshot.transmission) == str(Catalog.profile("toyota_mark_x").transmission), "controller did not bind catalog transmission")
    _check(is_equal_approx(float(snapshot.final_drive), float(Catalog.profile("toyota_mark_x").final_drive)), "controller did not expose selected final drive")
    _check(int(snapshot.gear_index) == 0, "controller did not reset into first forward gear")

    print("YARDMAN_POWERTRAIN_TEST %s vehicles=%d torque_curves=1 gearing=1 final_drive=1 controller=1" % ["PASS" if failures == 0 else "FAIL", Catalog.production_ids().size()])
    scene.queue_free()
    await process_frame
    quit(0 if failures == 0 else 1)
