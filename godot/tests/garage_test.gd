extends SceneTree

class FakeVehicle:
    extends RefCounted
    var applied := ""
    func apply_profile(vehicle_id: String) -> void:
        applied = vehicle_id

class FakeScene:
    extends Node
    var vehicle = FakeVehicle.new()

var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("GARAGE_TEST: " + message)

func _run() -> void:
    var garage = root.get_node_or_null("VehicleGarage")
    _check(garage != null, "VehicleGarage autoload missing")
    if garage == null:
        quit(1)
        return
    var ids: Array = garage.available_vehicle_ids()
    _check(ids.has("toyota_crown"), "Toyota Crown missing from garage")
    _check(ids.has("toyota_mark_x"), "Toyota Mark X missing from garage")
    _check(ids.has("port_royal_992"), "Port Royal 992 missing from garage")
    _check(garage.has_node("GarageUI/GarageButton"), "Touch-visible GARAGE button missing")
    _check(garage.has_node("GarageUI/GaragePanel/"), "Garage panel missing")

    var previous := garage.selected_vehicle_id()
    _check(garage.set_selected_vehicle("toyota_mark_x", false, false), "Could not select Mark X")
    _check(garage.selected_vehicle_id() == "toyota_mark_x", "Selection state did not update")
    var fake := FakeScene.new()
    root.add_child(fake)
    _check(garage.apply_selected_to_scene(fake), "Garage could not bridge selection to a vehicle controller")
    _check(fake.vehicle.applied == "toyota_mark_x", "Controller bridge received wrong vehicle id")
    garage.set_selected_vehicle(previous, false, false)
    fake.queue_free()
    await process_frame
    print("YARDMAN_GARAGE_TEST %s vehicles=%d button=1 bridge=1" % ["PASS" if failures == 0 else "FAIL", ids.size()])
    quit(0 if failures == 0 else 1)
