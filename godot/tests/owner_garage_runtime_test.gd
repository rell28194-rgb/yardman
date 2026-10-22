extends SceneTree

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("OWNER_GARAGE_RUNTIME: " + message)
    quit(1)

func _run() -> void:
    var err := change_scene_to_file("res://main.tscn")
    if err != OK:
        _fail("main scene failed to load: %s" % err)
        return
    for _i in range(20):
        await process_frame
    var garage := root.get_node_or_null("VehicleGarage")
    if garage == null:
        _fail("VehicleGarage autoload missing")
        return
    var download_status := root.get_node_or_null("DownloadStatus")
    if download_status == null:
        _fail("DownloadStatus autoload missing")
        return
    for _i in range(20):
        await process_frame

    var ids: Array = garage.get("_vehicle_ids")
    if ids.size() != 64:
        _fail("garage selector count=%d expected=64" % ids.size())
        return
    var button = garage.get("_button")
    var panel = garage.get("_panel")
    if button == null or not str(button.text).begins_with("GARAGE"):
        _fail("GARAGE control missing")
        return
    if int(garage.layer) < 100:
        _fail("garage canvas layer=%d expected mobile-HUD priority" % int(garage.layer))
        return
    if button.mouse_filter != Control.MOUSE_FILTER_STOP:
        _fail("GARAGE button does not stop GUI touch propagation")
        return
    if button.size.x < 200.0 or button.size.y < 54.0:
        _fail("GARAGE touch target too small: %s" % button.size)
        return

    var key := InputEventKey.new()
    key.pressed = true
    key.keycode = KEY_G
    key.physical_keycode = KEY_G
    if not bool(garage.call("_garage_key_pressed", key)):
        _fail("hardware G fallback is not recognized")
        return

    var game := current_scene
    var touch = game.get("touch") if game != null else null
    if touch == null:
        _fail("touch controls unavailable for garage arbitration test")
        return
    if bool(panel.visible):
        _fail("garage panel should start hidden")
        return
    garage.call("_toggle_panel")
    if not bool(panel.visible):
        _fail("garage panel did not open")
        return
    if bool(touch.get("input_enabled")):
        _fail("gameplay touch remained active while garage was open")
        return
    garage.call("_toggle_panel")
    if bool(panel.visible):
        _fail("garage panel did not close")
        return
    if not bool(touch.get("input_enabled")):
        _fail("gameplay touch was not restored after garage closed")
        return

    download_status.call("_on_source_state_changed", "downloading", "Downloading test content…", "TEST PACK")
    download_status.call("_on_source_progress", 50_000_000, 100_000_000, "TEST PACK")
    var snapshot: Dictionary = download_status.call("debug_snapshot")
    if not bool(snapshot.get("visible", false)):
        _fail("download status overlay is not visible during transfer")
        return
    if int(snapshot.get("layer", -1)) <= int(garage.layer):
        _fail("download overlay is not above garage/HUD")
        return
    if absf(float(snapshot.get("progress", -1.0)) - 50.0) > 0.1:
        _fail("download overlay progress is not real byte-derived percentage")
        return
    if not str(snapshot.get("detail", "")).contains("50.0 MB") or not str(snapshot.get("detail", "")).contains("50.0%"):
        _fail("download overlay does not expose transferred MB and percent")
        return
    download_status.call("_on_source_state_changed", "verifying", "Verifying downloaded files…", "TEST PACK")
    snapshot = download_status.call("debug_snapshot")
    if not str(snapshot.get("stage", "")).contains("VERIFYING"):
        _fail("download overlay does not expose verification stage")
        return

    var current := str(garage.get("_current_id"))
    if current != "toyota_crown":
        _fail("default vehicle=%s expected toyota_crown" % current)
        return
    if not bool(garage.call("_apply_vehicle", "audi_r8", false)):
        _fail("Crown -> Audi R8 runtime switch failed")
        return
    if str(garage.get("_current_id")) != "audi_r8":
        _fail("Audi R8 not active after switch")
        return
    if not bool(garage.call("_apply_vehicle", "toyota_crown", false)):
        _fail("Audi R8 -> Crown runtime switch failed")
        return
    if str(garage.get("_current_id")) != "toyota_crown":
        _fail("Crown not restored after switch")
        return
    print("YARDMAN_OWNER_GARAGE_RUNTIME_PASS selector=64 input=touch+G download_overlay=real_progress switch=toyota_crown>audi_r8>toyota_crown")
    quit(0)
