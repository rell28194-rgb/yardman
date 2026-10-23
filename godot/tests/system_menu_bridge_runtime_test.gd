extends SceneTree

const Bridge = preload("res://scripts/system_menu_bridge.gd")

func _initialize() -> void:
    call_deferred("_run")

func _fail(message: String) -> void:
    push_error("SYSTEM_MENU_BRIDGE_RUNTIME_TEST: " + message)
    quit(1)

func _make_launcher(owner_name: String, caption: String) -> Dictionary:
    var owner := Node.new()
    owner.name = owner_name
    var layer := CanvasLayer.new()
    owner.add_child(layer)
    var button := Button.new()
    button.text = caption
    layer.add_child(button)
    return {"owner": owner, "button": button}

func _run() -> void:
    var expected := {
        "EnvironmentContent": "CONTENT",
        "HydrologyContent": "RIVERS",
        "SurfaceContent": "SURFACES",
        "VehicleGarage": "GARAGE",
    }
    var suppressed := 0
    for owner_name: String in expected:
        var fixture := _make_launcher(owner_name, str(expected[owner_name]))
        var owner: Node = fixture.owner
        var button: Button = fixture.button
        if not Bridge.suppress_legacy_launcher(button):
            _fail("legacy launcher was not recognized: " + owner_name)
            return
        if button.visible or button.mouse_filter != Control.MOUSE_FILTER_IGNORE or button.focus_mode != Control.FOCUS_NONE:
            _fail("legacy launcher remains interactive/visible: " + owner_name)
            return
        if Bridge.launcher_owner_name(button) != owner_name:
            _fail("launcher ancestor resolution drifted: " + owner_name)
            return
        suppressed += 1
        owner.free()

    # The node-added path must perform suppression synchronously. A deferred
    # hide can still flash CONTENT/RIVERS/SURFACES/GARAGE for one rendered frame
    # because those optional autoloads build their launchers after this bridge.
    var live_bridge := Bridge.new()
    var first_frame_fixture := _make_launcher("EnvironmentContent", "CONTENT")
    var first_frame_button: Button = first_frame_fixture.button
    if not first_frame_button.visible:
        _fail("first-frame fixture did not begin visible")
        return
    live_bridge._on_node_added(first_frame_button)
    if first_frame_button.visible or first_frame_button.mouse_filter != Control.MOUSE_FILTER_IGNORE:
        _fail("node-added launcher suppression is deferred instead of immediate")
        return
    if int(live_bridge.debug_state().suppressed_launchers) != 1:
        _fail("synchronous launcher suppression was not counted")
        return
    first_frame_fixture.owner.free()
    live_bridge.free()

    # Download and action buttons inside those same runtimes must remain usable;
    # only the old top-level launcher captions are suppressed.
    var content_fixture := _make_launcher("EnvironmentContent", "DOWNLOAD BIOME HD")
    var action_button: Button = content_fixture.button
    if Bridge.suppress_legacy_launcher(action_button) or not action_button.visible:
        _fail("content action button was suppressed with the launcher")
        return
    content_fixture.owner.free()

    var unrelated_fixture := _make_launcher("UnrelatedRuntime", "CONTENT")
    var unrelated: Button = unrelated_fixture.button
    if Bridge.suppress_legacy_launcher(unrelated) or not unrelated.visible:
        _fail("unrelated UI was suppressed by caption alone")
        return
    unrelated_fixture.owner.free()

    # Normal HUD gets exactly one passive indicator. It is hidden outside active
    # transfer states and uses real byte totals when available.
    var idle := Bridge.download_indicator_model("VEHICLES", "idle", 0, 159594070)
    if bool(idle.visible) or bool(idle.show_bar):
        _fail("download indicator remains visible while idle")
        return
    var early := Bridge.download_indicator_model("VEHICLES", "downloading", 220000, 159594070)
    if not bool(early.visible) or not bool(early.show_bar) or not str(early.text).contains("VEHICLES 0.1%"):
        _fail("sub-percent resumable fleet progress is not visible")
        return
    if absf(float(early.percent) - (220000.0 / 159594070.0 * 100.0)) > 0.0001:
        _fail("download indicator percent is not based on real byte progress")
        return
    var middle := Bridge.download_indicator_model("ENV", "downloading", 24500000, 49000000, 1)
    if str(middle.text) != "↓ ENV 50% +1" or absf(float(middle.percent) - 50.0) > 0.001:
        _fail("compact concurrent-download indicator drifted")
        return
    var verifying := Bridge.download_indicator_model("SURFACES", "verifying", 1438240, 1438240)
    if not bool(verifying.visible) or bool(verifying.show_bar) or str(verifying.text) != "↓ SURFACES · VERIFY":
        _fail("verification stage does not replace misleading completed progress bar")
        return
    var installing := Bridge.download_indicator_model("RIVERS", "installing", 662099, 662099)
    if str(installing.text) != "↓ RIVERS · INSTALL":
        _fail("install stage label drifted")
        return
    if Bridge.DOWNLOAD_ORDER.size() != 4 or Bridge.DOWNLOAD_ACTIVE_STATES.size() != 4:
        _fail("consolidated download source/state contract drifted")
        return

    var project_text := FileAccess.get_file_as_string("res://project.godot")
    var bridge_pos := project_text.find("SystemMenuBridge=\"*res://scripts/system_menu_bridge.gd\"")
    if bridge_pos < 0:
        _fail("SystemMenuBridge autoload missing")
        return
    for marker in [
        "EnvironmentContent=\"*res://scripts/environment_content_runtime.gd\"",
        "HydrologyContent=\"*res://scripts/hydrology_content_runtime.gd\"",
        "SurfaceContent=\"*res://scripts/surface_content_runtime.gd\"",
        "VehicleGarage=\"*res://scripts/vehicle_selector_runtime.gd\"",
    ]:
        var runtime_pos := project_text.find(marker)
        if runtime_pos < 0 or bridge_pos >= runtime_pos:
            _fail("menu bridge no longer starts before launcher runtime: " + marker)
            return

    if Bridge.LEGACY_LAUNCHERS.size() != 4 or Bridge.RUNTIME_PANELS.size() != 4:
        _fail("consolidated runtime family count drifted")
        return

    print("YARDMAN_SYSTEM_MENU_BRIDGE_RUNTIME_TEST PASS launchers=4 actions_preserved=1 unrelated_preserved=1 preautoload=1 standalone_engineering_ui=0 download_sources=4 passive_indicator=1 subpercent=1 synchronous=1")
    quit(0)
