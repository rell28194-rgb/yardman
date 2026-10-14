extends SceneTree

class FakeVehicle:
    extends RefCounted
    var vehicle_id := "toyota_crown"
    var speed_mps := 0.0
    var calls := 0
    var reject_id := ""
    var ignore_id := ""
    var mutate_on_reject := false
    func apply_profile(requested_id: String) -> bool:
        calls += 1
        if requested_id == reject_id:
            if mutate_on_reject:
                vehicle_id = requested_id
            return false
        if requested_id != ignore_id:
            vehicle_id = requested_id
        return true

class LegacyVehicle:
    extends RefCounted
    var applied := ""
    func apply_profile(vehicle_id: String) -> void:
        applied = vehicle_id

class FakeScene:
    extends Node
    var vehicle: Object = FakeVehicle.new()

class TestGarage:
    extends "res://scripts/vehicle_garage.gd"
    var test_path := ""
    var reject_commit := false
    var reject_payment := false
    func _wallet_save_path() -> String:
        return test_path.get_base_dir().path_join("jobs.json")
    func _save_wallet() -> bool:
        return false if reject_payment else super._save_wallet()
    func _settings_path() -> String:
        return test_path
    func _commit_staged_selection() -> Error:
        if reject_commit:
            return ERR_FILE_CANT_WRITE
        return super._commit_staged_selection()

var failures := 0
var checks := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    checks += 1
    if not condition:
        failures += 1
        push_error("GARAGE_TEST: " + message)

func _stored_selection(path: String) -> String:
    if not FileAccess.file_exists(path):
        return ""
    var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
    return str(parsed.get("selected_vehicle", "")) if parsed is Dictionary else ""

func _run() -> void:
    var autoload = root.get_node_or_null("VehicleGarage")
    _check(autoload != null, "VehicleGarage autoload missing")
    if autoload == null:
        quit(1)
        return
    var ids: Array = autoload.available_vehicle_ids()
    _check(ids.has("toyota_crown") and ids.has("toyota_mark_x") and ids.has("port_royal_992"), "Production vehicles missing from garage")
    _check(autoload.has_node("GarageUI/GarageButton"), "Touch-visible GARAGE button missing")
    _check(autoload.has_node("GarageUI/GaragePanel"), "Garage panel missing")
    _check(autoload.get("_preview_model") == null, "Closed garage allocated a model before first open")
    _check(autoload.get("_preview_viewport").render_target_update_mode == SubViewport.UPDATE_DISABLED, "Closed garage viewport renders continuously")

    # The suite never overwrites the owner's saved selection. Disable unrelated
    # autoloads while using isolated scenes/controllers and a temporary path.
    var modes: Dictionary = {}
    for child in root.get_children():
        modes[child] = child.process_mode
        child.process_mode = Node.PROCESS_MODE_DISABLED
    var original_scene := current_scene
    var original_pause := paused
    paused = false
    var directory := "user://garage-test-%d" % Time.get_ticks_usec()
    var test_path := directory.path_join("vehicle.json")
    var garage := TestGarage.new()
    garage.test_path = test_path
    root.add_child(garage)
    garage.set_process(false)
    garage._owned_ids = ["toyota_crown", "toyota_mark_x", "port_royal_992"]
    var emitted: Array[String] = []
    garage.vehicle_selected.connect(func(vehicle_id: String) -> void: emitted.append(vehicle_id))

    _check(not garage.set_selected_vehicle("missing_vehicle", true, false), "Unknown vehicle accepted")
    _check(not garage.set_selected_vehicle("legacy_sedan", true, false), "Legacy fallback exposed as production selection")
    _check(not FileAccess.file_exists(test_path), "Rejected selection wrote settings")
    _check(garage.set_selected_vehicle("toyota_mark_x", true, false), "Could not persist Mark X selection")
    _check(garage.selected_vehicle_id() == "toyota_mark_x", "Selection state did not update")
    _check(_stored_selection(test_path) == "toyota_mark_x", "Persistent selection stored the wrong vehicle")
    _check(emitted.is_empty(), "Next-launch-only selection emitted a live switch")
    _check(not FileAccess.file_exists(garage._staged_settings_path()), "Successful save left a staging file")
    _check(garage.get("_preview_model") == null, "Hidden selection allocated a preview model")

    var scene := FakeScene.new()
    root.add_child(scene)
    current_scene = scene
    garage._process(0.0)
    _check(scene.vehicle.vehicle_id == "toyota_mark_x", "Scene did not receive persisted selection")
    _check(emitted == ["toyota_mark_x"], "Initial scene application did not emit exactly once")
    var calls: int = scene.vehicle.calls
    garage._process(0.0)
    _check(scene.vehicle.calls == calls, "Unchanged scene reapplies its profile every frame")
    emitted.clear()

    _check(garage.set_selected_vehicle("toyota_crown", true, true), "Live Crown switch failed")
    _check(scene.vehicle.vehicle_id == "toyota_crown" and garage.selected_vehicle_id() == "toyota_crown", "Live and selected profiles disagree")
    _check(_stored_selection(test_path) == "toyota_crown", "Live switch did not persist")
    _check(emitted == ["toyota_crown"], "Successful live switch emitted incorrectly")
    emitted.clear()
    var saved_bytes := FileAccess.get_file_as_bytes(test_path)

    scene.vehicle.reject_id = "toyota_mark_x"
    _check(not garage.set_selected_vehicle("toyota_mark_x", true, true), "Controller rejection reported success")
    _check(garage.selected_vehicle_id() == "toyota_crown" and scene.vehicle.vehicle_id == "toyota_crown", "Rejected controller changed selected vehicle")
    _check(FileAccess.get_file_as_bytes(test_path) == saved_bytes, "Rejected switch overwrote saved selection")
    _check(emitted.is_empty(), "Rejected switch emitted a selection signal")
    _check(not FileAccess.file_exists(garage._staged_settings_path()), "Rejected switch retained staging file")
    scene.vehicle.mutate_on_reject = true
    _check(not garage.set_selected_vehicle("toyota_mark_x", true, true), "Partially failed controller reported success")
    _check(scene.vehicle.vehicle_id == "toyota_crown", "Partially failed controller did not roll back")
    scene.vehicle.reject_id = ""
    scene.vehicle.ignore_id = "toyota_mark_x"
    _check(not garage.set_selected_vehicle("toyota_mark_x", true, true), "No-op controller reported a successful switch")
    _check(garage.selected_vehicle_id() == "toyota_crown", "No-op controller changed selected profile")
    scene.vehicle.ignore_id = ""

    for speed in [2.0, -2.0, NAN, INF]:
        scene.vehicle.speed_mps = speed
        calls = scene.vehicle.calls
        _check(not garage.set_selected_vehicle("toyota_mark_x", true, true), "Unsafe speed bypassed public switching guard: %s" % speed)
        _check(scene.vehicle.calls == calls and FileAccess.get_file_as_bytes(test_path) == saved_bytes, "Motion guard changed controller or persistence")
    scene.vehicle.speed_mps = 0.0

    garage.reject_commit = true
    _check(not garage.set_selected_vehicle("toyota_mark_x", true, true), "Persistence commit failure reported success")
    _check(scene.vehicle.vehicle_id == "toyota_crown" and garage.selected_vehicle_id() == "toyota_crown", "Persistence commit failure did not roll back vehicle")
    _check(FileAccess.get_file_as_bytes(test_path) == saved_bytes, "Persistence failure corrupted old settings")
    _check(garage.last_selection_error() == "COULD NOT SAVE VEHICLE SELECTION", "Persistence failure was misreported")
    _check(emitted.is_empty(), "Failed commit emitted a successful switch")
    _check(not FileAccess.file_exists(garage._staged_settings_path()), "Failed commit left staging data")
    garage.reject_commit = false

    var blocker_path := directory.path_join("file-not-directory")
    var blocker := FileAccess.open(blocker_path, FileAccess.WRITE)
    blocker.store_string("block settings directory creation")
    blocker.close()
    garage.test_path = blocker_path.path_join("vehicle.json")
    calls = scene.vehicle.calls
    _check(not garage.set_selected_vehicle("toyota_mark_x", true, true), "Settings write failure reported success")
    _check(scene.vehicle.calls == calls and garage.selected_vehicle_id() == "toyota_crown", "Failed settings preparation touched controller")
    garage.test_path = test_path

    var next_scene := FakeScene.new()
    next_scene.vehicle.vehicle_id = "toyota_mark_x"
    root.add_child(next_scene)
    current_scene = next_scene
    garage._process(0.0)
    _check(next_scene.vehicle.vehicle_id == "toyota_crown", "Replacement scene retained wrong vehicle")
    var replacement := FakeVehicle.new()
    replacement.vehicle_id = "port_royal_992"
    next_scene.vehicle = replacement
    garage._process(0.0)
    _check(replacement.vehicle_id == "toyota_crown" and replacement.calls == 1, "Replacement controller was not initialized")
    var legacy := LegacyVehicle.new()
    next_scene.vehicle = legacy
    _check(garage.apply_selected_to_scene(next_scene) and legacy.applied == "toyota_crown", "Void-returning legacy controller bridge broke")
    next_scene.vehicle = replacement

    var jobs = root.get_node("JobRuntime")
    var original_wallet: int = int(jobs.wallet_jmd)
    jobs.wallet_jmd = 100000
    garage._owned_ids.erase("port_royal_992")
    next_scene.vehicle = replacement
    var price: int = garage.vehicle_price_jmd("port_royal_992")
    replacement.speed_mps = 3.0
    _check(not garage.purchase_vehicle("port_royal_992"), "Purchase bypassed motion guard")
    _check(jobs.wallet_jmd == 100000 and not garage.is_vehicle_owned("port_royal_992"), "Motion guard charged wallet or granted ownership")
    replacement.speed_mps = 0.0
    replacement.reject_id = "port_royal_992"
    _check(not garage.purchase_vehicle("port_royal_992"), "Rejected purchase controller reported success")
    _check(jobs.wallet_jmd == 100000 and not garage.is_vehicle_owned("port_royal_992"), "Rejected purchase failed to refund or revoke ownership")
    _check(_stored_selection(test_path) == "toyota_crown", "Failed purchase changed saved vehicle")
    replacement.reject_id = ""
    garage.reject_commit = true
    _check(not garage.purchase_vehicle("port_royal_992"), "Failed purchase commit reported success")
    _check(jobs.wallet_jmd == 100000 and replacement.vehicle_id == "toyota_crown", "Failed purchase commit lost money or live vehicle")
    _check(not garage.is_vehicle_owned("port_royal_992"), "Failed purchase commit retained ownership")
    garage.reject_commit = false
    garage.reject_payment = true
    _check(not garage.purchase_vehicle("port_royal_992"), "Failed payment persistence reported success")
    _check(jobs.wallet_jmd == 100000 and not garage.is_vehicle_owned("port_royal_992"), "Failed payment persistence changed wallet/ownership")
    garage.reject_payment = false
    _check(garage.purchase_vehicle("port_royal_992"), "Valid vehicle purchase failed")
    _check(jobs.wallet_jmd == 100000 - price and garage.is_vehicle_owned("port_royal_992"), "Valid purchase did not debit exact price/grant ownership")
    _check(replacement.vehicle_id == "port_royal_992", "Purchased vehicle was not applied")
    _check(garage.purchase_vehicle("port_royal_992") and jobs.wallet_jmd == 100000 - price, "Owned vehicle was charged twice")
    _check(garage.set_selected_vehicle("toyota_crown"), "Could not restore Crown after purchase checks")
    jobs.wallet_jmd = original_wallet
    jobs._update_ui()
    emitted.clear()

    garage.open_garage()
    _check(garage.is_open() and paused, "Garage did not open and pause gameplay")
    _check(garage.get("_modal").visible and garage.get("_modal").mouse_filter == Control.MOUSE_FILTER_STOP, "Fullscreen modal does not block underlying UI")
    _check(garage.get("_preview_viewport").render_target_update_mode == SubViewport.UPDATE_ALWAYS, "Visible preview did not resume rendering")
    var first_preview: Node3D = garage.get("_preview_model")
    _check(first_preview != null and first_preview.get_meta("yardman_vehicle_visual_id", "") == "toyota_crown", "Initial preview was not styled for selected vehicle")
    var selector: OptionButton = garage.get("_selector")
    for index in range(selector.item_count):
        if str(selector.get_item_metadata(index)) == "port_royal_992":
            selector.select(index)
            garage._on_preview_selected(index)
            break
    var candidate_preview: Node3D = garage.get("_preview_model")
    _check(candidate_preview != first_preview and candidate_preview.get_meta("yardman_vehicle_visual_id", "") == "port_royal_992", "Candidate preview retained selected vehicle styling")
    _check(garage.selected_vehicle_id() == "toyota_crown" and replacement.vehicle_id == "toyota_crown", "Preview selection changed live vehicle")
    _check(_stored_selection(test_path) == "toyota_crown", "Preview selection changed persistent vehicle")
    _check(not str(garage.get("_info").text).contains("integration pending") and not str(garage.get("_info").text).contains("Audio profile"), "Garage exposes implementation metadata")
    garage._refresh_preview()
    _check(garage.get("_preview_model") == candidate_preview, "Unchanged candidate rebuilt its model")
    garage.open_garage()
    _check(garage.get("_preview_model") == candidate_preview, "Repeated open lost the candidate")
    garage.close_garage()
    _check(not garage.is_open() and not paused, "Garage did not restore its owned pause")
    _check(not garage.get("_modal").visible, "Closed garage retains modal blocker")
    _check(garage.get("_preview_viewport").render_target_update_mode == SubViewport.UPDATE_DISABLED, "Closed preview continues rendering")
    var hidden_rotation := candidate_preview.rotation
    garage._process(1.0)
    _check(candidate_preview.rotation == hidden_rotation, "Closed preview continues rotating")

    paused = true
    garage.open_garage()
    garage.close_garage()
    _check(paused, "Garage cleared another system's pre-existing pause")
    paused = false
    garage.open_garage()
    var escape := InputEventKey.new()
    escape.physical_keycode = KEY_ESCAPE
    escape.pressed = true
    garage._input(escape)
    _check(not garage.is_open() and not paused, "Escape did not close the garage and restore gameplay")
    replacement.speed_mps = 3.0
    garage.open_garage()
    _check(garage.get("_apply_button").disabled, "Moving vehicle can be switched from garage UI")
    garage.close_garage()
    replacement.speed_mps = 0.0

    current_scene = null
    _check(not garage.set_selected_vehicle("toyota_mark_x", true, true), "Missing live scene reported switch success")
    _check(_stored_selection(test_path) == "toyota_crown", "Missing scene changed saved selection")
    garage.open_garage()
    garage.free()
    _check(not paused, "Removing open garage leaked its pause")
    scene.free()
    next_scene.free()
    current_scene = original_scene
    paused = original_pause
    for child in modes:
        if is_instance_valid(child):
            child.process_mode = modes[child]
    for suffix in ["", ".bak", ".tmp"]:
        var wallet_path: String = directory.path_join("jobs.json") + str(suffix)
        if FileAccess.file_exists(wallet_path):
            DirAccess.remove_absolute(ProjectSettings.globalize_path(wallet_path))
    DirAccess.remove_absolute(ProjectSettings.globalize_path(test_path))
    DirAccess.remove_absolute(ProjectSettings.globalize_path(blocker_path))
    DirAccess.remove_absolute(ProjectSettings.globalize_path(directory))
    await process_frame
    print("YARDMAN_GARAGE_TEST %s checks=%d vehicles=%d transaction=1 failure_rollback=1 scene_rebind=1 preview=1 pause=1 persistence=1" % ["PASS" if failures == 0 else "FAIL", checks, ids.size()])
    quit(0 if failures == 0 else 1)
