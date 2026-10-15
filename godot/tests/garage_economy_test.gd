extends SceneTree

class TestGarage:
    extends "res://scripts/vehicle_garage.gd"
    var directory := ""
    func _settings_path() -> String:
        return directory.path_join("vehicle.json")
    func _wallet_save_path() -> String:
        return directory.path_join("jobs.json")

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

func _capture_file(path: String) -> Dictionary:
    return {
        "exists": FileAccess.file_exists(path),
        "text": FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else "",
    }

func _restore_file(path: String, snapshot: Dictionary) -> void:
    var absolute := ProjectSettings.globalize_path(path)
    if bool(snapshot.get("exists", false)):
        DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
        var file := FileAccess.open(path, FileAccess.WRITE)
        if file != null:
            file.store_string(str(snapshot.get("text", "")))
            file.flush()
            file.close()
    elif FileAccess.file_exists(path):
        DirAccess.remove_absolute(absolute)

func _run() -> void:
    var production_garage = root.get_node_or_null("VehicleGarage")
    var jobs = root.get_node_or_null("JobRuntime")
    _check(production_garage != null, "VehicleGarage autoload missing")
    _check(jobs != null, "JobRuntime autoload missing")
    if production_garage == null or jobs == null:
        quit(1)
        return

    # Keep every generated purchase and save out of the owner's normal files.
    var modes: Dictionary = {}
    for child in root.get_children():
        modes[child] = child.process_mode
        child.process_mode = Node.PROCESS_MODE_DISABLED
    var original_jobs: Dictionary = jobs.call("save_snapshot")
    var garage := TestGarage.new()
    garage.directory = "user://garage-economy-test-%d" % Time.get_ticks_usec()
    root.add_child(garage)
    garage.set_process(false)

    var ids: Array = garage.available_vehicle_ids()
    _check(ids.has("toyota_crown"), "Toyota Crown missing from garage")
    _check(ids.has("toyota_mark_x"), "Toyota Mark X missing from garage")
    _check(ids.has("port_royal_992"), "Port Royal 992 missing from garage")
    _check(garage.has_node("GarageUI/GarageButton"), "Touch-visible GARAGE button missing")
    _check(garage.has_node("GarageUI/GaragePanel"), "Garage panel missing")
    _check(garage.vehicle_price_jmd("toyota_crown") == 0, "starter Crown must remain free")
    _check(garage.vehicle_price_jmd("toyota_mark_x") == 32000, "Mark X price drifted")
    _check(garage.vehicle_price_jmd("port_royal_992") == 95000, "Port Royal 992 price drifted")

    var migrated: Array[String] = garage.normalized_owned_ids([], "port_royal_992")
    _check(migrated.has("toyota_crown"), "ownership migration lost starter Crown")
    _check(migrated.has("port_royal_992"), "legacy selected vehicle was not grandfathered")

    var settings_path := garage._settings_path()
    var jobs_path := garage._wallet_save_path()
    var vehicle_before := _capture_file(settings_path)
    var jobs_before := _capture_file(jobs_path)
    var jobs_backup_before := _capture_file(jobs_path + ".bak")
    var wallet_before := int(jobs.get("wallet_jmd"))

    if FileAccess.file_exists(settings_path):
        DirAccess.remove_absolute(ProjectSettings.globalize_path(settings_path))
    garage.call("_load_selection")
    _check(garage.selected_vehicle_id() == "toyota_crown", "fresh garage did not select starter Crown")
    _check(garage.is_vehicle_owned("toyota_crown"), "fresh garage does not own starter Crown")
    _check(not garage.is_vehicle_owned("toyota_mark_x"), "fresh garage incorrectly owns Mark X")

    jobs.set("wallet_jmd", 100000)
    var price: int = int(garage.vehicle_price_jmd("toyota_mark_x"))
    var balance_before := int(jobs.get("wallet_jmd"))
    _check(garage.purchase_vehicle("toyota_mark_x", false), "Mark X purchase failed with sufficient wallet")
    _check(garage.is_vehicle_owned("toyota_mark_x"), "purchased Mark X did not become owned")
    _check(garage.selected_vehicle_id() == "toyota_mark_x", "purchased Mark X did not become selected")
    _check(int(jobs.get("wallet_jmd")) == balance_before - price, "vehicle purchase debited wrong wallet amount")
    _check(not garage.purchase_vehicle("unknown_vehicle", false), "unknown vehicle purchase was accepted")

    _check(FileAccess.file_exists(settings_path), "persistent garage state file was not written")
    if FileAccess.file_exists(settings_path):
        var parsed = JSON.parse_string(FileAccess.get_file_as_string(settings_path))
        _check(parsed is Dictionary, "persistent garage state is not valid JSON")
        if parsed is Dictionary:
            _check(str(parsed.get("selected_vehicle", "")) == "toyota_mark_x", "garage stored the wrong selected vehicle")
            var owned = parsed.get("owned_vehicles", [])
            _check(owned is Array and (owned as Array).has("toyota_mark_x"), "garage did not persist purchased ownership")

    var fake: FakeScene = FakeScene.new()
    root.add_child(fake)
    _check(garage.apply_selected_to_scene(fake), "Garage could not bridge selection to a vehicle controller")
    _check(fake.vehicle.applied == "toyota_mark_x", "Controller bridge received wrong vehicle id")
    fake.queue_free()
    await process_frame

    jobs.set("wallet_jmd", wallet_before)
    if jobs.has_method("_update_ui"):
        jobs.call("_update_ui")
    _restore_file(settings_path, vehicle_before)
    _restore_file(jobs_path, jobs_before)
    _restore_file(jobs_path + ".bak", jobs_backup_before)
    garage.call("_load_selection")

    jobs.call("restore_snapshot", original_jobs)
    var directory := ProjectSettings.globalize_path(garage.directory)
    garage.queue_free()
    await process_frame
    for entry in DirAccess.get_files_at(directory):
        DirAccess.remove_absolute(directory.path_join(entry))
    if DirAccess.dir_exists_absolute(directory):
        DirAccess.remove_absolute(directory)
    for child in modes:
        if is_instance_valid(child):
            child.process_mode = modes[child]

    print("YARDMAN_GARAGE_ECONOMY_TEST %s vehicles=%d purchase=1 ownership=1 migration=1 bridge=1 persistence=1" % ["PASS" if failures == 0 else "FAIL", ids.size()])
    quit(0 if failures == 0 else 1)
