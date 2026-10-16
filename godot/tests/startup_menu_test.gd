extends SceneTree

const StartupMenu = preload("res://scripts/startup_menu.gd")
var failures := 0

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, message: String) -> void:
    if not condition:
        failures += 1
        push_error("STARTUP_MENU_TEST: " + message)

func _collect_buttons(node: Node, labels: Dictionary) -> void:
    if node is Button:
        labels[(node as Button).text] = true
    for child in node.get_children():
        _collect_buttons(child, labels)

func _run() -> void:
    var menu := StartupMenu.new()
    menu._build_ui()
    var labels: Dictionary = {}
    _collect_buttons(menu, labels)
    _check(menu.screen != null and menu.screen.name == "StartupMenuScreen", "startup overlay was not constructed")
    _check(menu.continue_button != null, "continue drive button is missing")
    _check(str(menu.continue_button.text) == "CONTINUE DRIVE", "continue drive button label changed unexpectedly")
    _check(menu.garage_button != null, "vehicle garage button is missing")
    _check(str(menu.garage_button.text) == "VEHICLE GARAGE", "vehicle garage button label changed unexpectedly")
    _check(labels.has("VEHICLE GARAGE"), "vehicle selection is not exposed from the startup menu")
    _check(labels.has("START / RESTART SELECTED PARISH"), "explicit start/restart parish button is missing")
    _check(menu.screen.mouse_filter == Control.MOUSE_FILTER_STOP, "startup overlay no longer accepts touch input")
    menu.free()
    print("YARDMAN_STARTUP_MENU_TEST %s continue_button=1 garage_button=1 start_button=1 touch_overlay=1" % ("PASS" if failures == 0 else "FAIL"))
    quit(0 if failures == 0 else 1)
