extends SceneTree

class FakeVehicle:
    extends RefCounted
    var applied := ""
    func apply_profile(vehicle_id: String) -> void:
        applied = vehicle_id

class FakeScene:
    extends Node
    var vehicle: FakeVehicle = FakeVehicle.new()

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
    _check(garage.has_node("GarageUI/GaragePanel"), "Garage panel missing")

    var previous: String = str(garage.selected_vehicle_id())
    _check(garage.set_selected_vehicle("toyota_mark_x", true, false), "Could not persist Mark X selection")
    _check(garage.selected_vehicle_id() == "toyota_mark_x", "Selection state did not update")
    var settings_path := "user://yardman/vehicle.json"
    _check(FileAccess.file_exists(settings_path), "Persistent garage selection file was not written")
    if FileAccess.file_exists(settings_path):
        var parsed = JSON.parse_string(FileAccess.get_file_as_string(settings_path))
        _check(parsed is Dictionary, "Persistent garage selection is not valid JSON")
        if parsed is Dictionary:
            _check(str(parsed.get("selected_vehicle", "")) == "toyota_mark_x", "Persistent garage selection stored the wrong vehicle")

    var fake: FakeScene = FakeScene.new()
    root.add_child(fake)
    _check(garage.apply_selected_to_scene(fake), "Garage could not bridge selection to a vehicle controller")
    _check(fake.vehicle.applied == "toyota_mark_x", "Controller bridge received wrong vehicle id")
    _check(garage.set_selected_vehicle(previous, true, false), "Could not restore previous persisted vehicle")
    fake.queue_free()
    await process_frame
    print("YARDMAN_GARAGE_TEST %s vehicles=%d button=1 bridge=1 persistence=1" % ["PASS" if failures == 0 else "FAIL", ids.size()])
    quit(0 if failures == 0 else 1)
