extends SceneTree

const Access = preload("res://scripts/garage_access_runtime.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if condition:
        return
    failures += 1
    push_error("GARAGE_ACCESS_RUNTIME: " + message)

func _run() -> void:
    var err := change_scene_to_file("res://main.tscn")
    _check(err == OK, "main scene failed to load")
    if err != OK:
        quit(1)
        return
    for _i in range(6):
        await process_frame

    var game := current_scene
    var access := game.get_node_or_null("GarageAccess") if game != null else null
    var garage := root.get_node_or_null("VehicleGarage")
    _check(access != null, "GarageAccess runtime missing")
    _check(garage != null, "VehicleGarage autoload missing")
    if access != null and garage != null:
        _check(bool(access.call("open_garage")), "open_garage failed")
        var panel: Variant = garage.get("_panel")
        _check(panel is PanelContainer, "garage panel was not primed")
        if panel is PanelContainer:
            _check((panel as PanelContainer).visible, "garage panel did not open")
            access.call("close_garage")
            _check(not (panel as PanelContainer).visible, "garage panel did not close")
            access.call("toggle_garage")
            _check((panel as PanelContainer).visible, "garage toggle did not reopen")

        var contract: Dictionary = Access.access_contract()
        _check(not bool(contract.get("controller_required_for_open", true)), "garage still depends on vehicle controller attach")
        _check(str(contract.get("keyboard_fallback", "")) == "G", "G fallback missing")
        _check(not bool(contract.get("duplicate_garage", true)), "access layer duplicated garage")
        _check(not bool(contract.get("hud_launcher", true)), "access layer added a HUD launcher")

    if failures == 0:
        print("YARDMAN_GARAGE_ACCESS_RUNTIME_PASS startup=1 open=1 close=1 toggle=1 controller_independent=1 keyboard_g=1 duplicate=0 hud_launcher=0")
        quit(0)
        return
    print("YARDMAN_GARAGE_ACCESS_RUNTIME_FAIL count=%d" % failures)
    quit(1)
