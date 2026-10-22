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

    print("YARDMAN_SYSTEM_MENU_BRIDGE_RUNTIME_TEST PASS launchers=4 actions_preserved=1 unrelated_preserved=1 preautoload=1 standalone_engineering_ui=0")
    quit(0)
