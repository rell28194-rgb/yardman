extends SceneTree

const Persistence = preload("res://scripts/job_persistence_runtime.gd")

class TestGarage:
    extends "res://scripts/vehicle_garage.gd"
    var directory := ""
    var saves := 0
    var fail_save := 0
    var reject_selection := false
    var debit_state: Dictionary = {}
    var selection_at_debit := ""
    func _settings_path() -> String:
        return directory.path_join("vehicle.json")
    func _wallet_save_path() -> String:
        return directory.path_join("jobs.json")
    func _save_wallet() -> bool:
        saves += 1
        if saves == fail_save:
            return false
        var result := super._save_wallet()
        if result and saves == 1:
            debit_state = Persistence.read_state(_wallet_save_path())
            selection_at_debit = FileAccess.get_file_as_string(_settings_path())
        return result
    func _commit_staged_selection() -> Error:
        return ERR_FILE_CANT_WRITE if reject_selection else super._commit_staged_selection()

var failures := 0
var checks := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    checks += 1
    if not condition:
        failures += 1
        push_error("GARAGE_PURCHASE_RECOVERY: " + message)

func _write(path: String, text: String) -> void:
    var file := FileAccess.open(path, FileAccess.WRITE)
    _check(file != null, "fixture write failed")
    if file != null:
        file.store_string(text)
        file.close()

func _seed(garage: TestGarage, runtime: Node) -> Dictionary:
    var state := {"wallet_jmd": 100000, "offer_sequence": 7, "active_job": {},
        "garage_owned_ids": ["toyota_crown"]}
    _check(Persistence.write_state(garage._wallet_save_path(), state) == OK, "baseline save failed")
    _write(garage._settings_path(), JSON.stringify({"selected_vehicle": "toyota_crown", "owned_vehicles": ["toyota_crown"]}))
    runtime.call("restore_snapshot", state)
    garage._load_selection()
    garage.saves = 0
    garage.fail_save = 0
    garage.reject_selection = false
    return state

func _run() -> void:
    var runtime := root.get_node("JobRuntime")
    var original: Dictionary = runtime.call("save_snapshot")
    var modes: Dictionary = {}
    for child in root.get_children():
        modes[child] = child.process_mode
        child.process_mode = Node.PROCESS_MODE_DISABLED
    var garage := TestGarage.new()
    garage.directory = "user://purchase-recovery-test-%d" % Time.get_ticks_usec()
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(garage.directory))
    root.add_child(garage)
    garage.set_process(false)
    var before := _seed(garage, runtime)
    _check(garage.purchase_vehicle("toyota_mark_x", false), "valid purchase failed")
    _check(garage.debit_state.get("wallet_jmd") == 68000, "captured debit was not exact")
    _check(garage.debit_state.get("garage_owned_ids", []).has("toyota_mark_x"), "debit reached disk without ownership")
    var old_selection = JSON.parse_string(garage.selection_at_debit)
    _check(old_selection.selected_vehicle == "toyota_crown", "cut point was not before selection commit")

    # Recreate the exact persisted files at the debit/selection cut, discard
    # live state, and run the same load used by a fresh garage autoload.
    _check(Persistence.write_state(garage._wallet_save_path(), garage.debit_state) == OK, "cut-point wallet restore failed")
    _write(garage._settings_path(), garage.selection_at_debit)
    runtime.call("restore_snapshot", Persistence.read_state(garage._wallet_save_path()))
    garage._load_selection()
    _check(garage.wallet_jmd() == 68000 and garage.is_vehicle_owned("toyota_mark_x"), "restart lost money or the paid vehicle")
    _check(garage.selected_vehicle_id() == "toyota_crown", "interruption discarded the prior selection")
    _check(garage.purchase_vehicle("toyota_mark_x", false), "recovered owned car could not be selected")
    _check(garage.wallet_jmd() == 68000, "recovered car was charged twice")
    var autosave: Dictionary = runtime.call("save_snapshot")
    _check(autosave.get("garage_owned_ids", []).has("toyota_mark_x"), "normal job autosave dropped paid ownership")
    _check(int(autosave.offer_sequence) == 7, "purchase altered unrelated job state")

    # Missing/corrupt vehicle.json cannot erase ownership from a paid wallet.
    DirAccess.remove_absolute(garage._settings_path())
    garage._load_selection()
    _check(garage.is_vehicle_owned("toyota_mark_x"), "missing selection file lost paid ownership")
    _write(garage._settings_path(), "broken JSON")
    garage._load_selection()
    _check(garage.is_vehicle_owned("toyota_mark_x"), "corrupt selection file lost paid ownership")

    # An interrupted atomic replacement must recover the OLD wallet AND old
    # ownership from .bak; stale selection-cache ownership cannot grant a car.
    before = _seed(garage, runtime)
    var pending := before.duplicate(true)
    pending.wallet_jmd = 68000
    pending.garage_owned_ids = ["toyota_crown", "toyota_mark_x"]
    _write(garage._wallet_save_path() + ".tmp", JSON.stringify(Persistence.wrap_state(pending)))
    DirAccess.remove_absolute(garage._wallet_save_path() + ".bak")
    _check(DirAccess.rename_absolute(garage._wallet_save_path(), garage._wallet_save_path() + ".bak") == OK, "could not create atomic-rename cut point")
    _write(garage._settings_path(), JSON.stringify({"selected_vehicle": "toyota_mark_x", "owned_vehicles": ["toyota_crown", "toyota_mark_x"]}))
    runtime.call("restore_snapshot", Persistence.read_state(garage._wallet_save_path()))
    garage._load_selection()
    _check(garage.wallet_jmd() == 100000 and not garage.is_vehicle_owned("toyota_mark_x"), "backup recovery mixed two purchase generations")
    _check(garage.selected_vehicle_id() == "toyota_crown", "stale cache selected an unowned car")
    _write(garage._wallet_save_path(), "broken JSON")
    var backup := Persistence.read_state(garage._wallet_save_path())
    _check(backup.get("wallet_jmd") == 100000 and backup.get("garage_owned_ids") == ["toyota_crown"],
        "corrupt primary did not recover a matching backup wallet/ownership pair")

    # Failed selection normally refunds both fields in one save.
    _seed(garage, runtime)
    garage.reject_selection = true
    _check(not garage.purchase_vehicle("toyota_mark_x", false), "selection failure reported success")
    var refunded := Persistence.read_state(garage._wallet_save_path())
    _check(refunded.wallet_jmd == 100000 and not refunded.garage_owned_ids.has("toyota_mark_x"), "refund did not persist money and ownership together")

    # If refund persistence also fails, retain the durable paid car and debit,
    # then let retry select it without charging again.
    _seed(garage, runtime)
    garage.reject_selection = true
    garage.fail_save = 2
    var selector: OptionButton = garage.get("_selector")
    for index in range(selector.item_count):
        if str(selector.get_item_metadata(index)) == "toyota_mark_x":
            selector.select(index)
    garage._refresh_preview()
    _check(not garage.purchase_vehicle("toyota_mark_x", false), "failed refund reported normal purchase success")
    _check(garage.wallet_jmd() == 68000 and garage.is_vehicle_owned("toyota_mark_x"), "failed refund left memory inconsistent with the paid record")
    _check(str(garage.get("_info").text).contains("OWNED") and str(garage.get("_info").text).contains("68000"),
        "failed refund left the garage displaying the wrong ownership or wallet")
    garage.reject_selection = false
    _check(garage.purchase_vehicle("toyota_mark_x", false) and garage.wallet_jmd() == 68000, "retry after failed refund charged twice")
    garage._load_selection()
    _check(garage.is_vehicle_owned("toyota_mark_x"), "failed-refund restart lost the car")

    # Old saves retain the previous selected/owned migration policy.
    _check(Persistence.write_state(garage._wallet_save_path(), {"wallet_jmd": 5000, "offer_sequence": 0, "active_job": {}}) == OK, "legacy fixture failed")
    _write(garage._settings_path(), JSON.stringify({"selected_vehicle": "port_royal_992"}))
    garage._load_selection()
    _check(garage.is_vehicle_owned("port_royal_992"), "legacy selection migration lost an existing car")

    # The FIRST purchase must create a legacy ownership baseline so falling
    # back to .bak never combines an old wallet with the newer selection cache.
    var legacy := {"wallet_jmd": 100000, "offer_sequence": 0, "active_job": {}}
    _check(Persistence.write_state(garage._wallet_save_path(), legacy) == OK, "first-purchase legacy wallet fixture failed")
    _write(garage._settings_path(), JSON.stringify({"selected_vehicle": "toyota_crown"}))
    runtime.call("restore_snapshot", legacy)
    garage._load_selection()
    garage.saves = 0
    garage.fail_save = 0
    _check(garage.purchase_vehicle("toyota_mark_x", false), "first legacy purchase failed")
    var first_backup := Persistence._read_valid(garage._wallet_save_path() + ".bak")
    _check(first_backup.get("wallet_jmd") == 100000 and first_backup.get("garage_owned_ids") == ["toyota_crown"],
        "first purchase backup lacks an atomic legacy baseline")
    _write(garage._wallet_save_path(), "corrupt paid primary")
    runtime.call("restore_snapshot", Persistence.read_state(garage._wallet_save_path()))
    garage._load_selection()
    _check(garage.wallet_jmd() == 100000 and not garage.is_vehicle_owned("toyota_mark_x")
        and garage.selected_vehicle_id() == "toyota_crown", "legacy backup recovery granted a free paid car")

    # A failed installation after recovery must preserve the LAST GOOD backup,
    # rather than rotating the corrupt primary over it.
    var recovered := Persistence.read_state(garage._wallet_save_path())
    var missing_temporary := garage.directory.path_join("missing.tmp")
    _check(Persistence._commit_staged(missing_temporary, garage._wallet_save_path()) != OK,
        "missing staged save did not simulate installation failure")
    _check(Persistence.read_state(garage._wallet_save_path()) == recovered,
        "failed save after recovery destroyed the good wallet/ownership checkpoint")
    # The successful path must also retain a good backup if interrupted later.
    _write(garage._wallet_save_path(), "corrupt primary again")
    _write(garage._wallet_save_path() + ".bak", JSON.stringify(Persistence.wrap_state(recovered)))
    var next := recovered.duplicate(true)
    next.wallet_jmd = 105000
    _check(Persistence.write_state(garage._wallet_save_path(), next) == OK, "save after backup recovery failed")
    _check(Persistence._read_valid(garage._wallet_save_path() + ".bak") == recovered,
        "save after backup recovery replaced the valid backup with corrupt data")
    _check(Persistence.read_state(garage._wallet_save_path()).wallet_jmd == 105000,
        "save after backup recovery did not install the new wallet")

    runtime.call("restore_snapshot", original)
    var test_directory := ProjectSettings.globalize_path(garage.directory)
    garage.queue_free()
    await process_frame
    # The unique test directory contains only generated JSON; remove it without
    # touching the owner's normal settings or wallet files.
    for file in DirAccess.get_files_at(test_directory):
        DirAccess.remove_absolute(test_directory.path_join(file))
    DirAccess.remove_absolute(test_directory)
    for child in modes:
        if is_instance_valid(child):
            child.process_mode = modes[child]
    print("YARDMAN_GARAGE_PURCHASE_RECOVERY_TEST %s checks=%d" % ["PASS" if failures == 0 else "FAIL", checks])
    quit(0 if failures == 0 else 1)
