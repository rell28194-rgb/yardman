extends Node
class_name YardmanGarageAccessRuntime

var _garage: Node
var _primed := false
var _clock := 0.0

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    set_process(true)
    call_deferred("_prime")

func _process(delta: float) -> void:
    if _primed:
        set_process(false)
        return
    _clock += maxf(delta, 0.0)
    if _clock < 0.20:
        return
    _clock = 0.0
    _prime()

func _prime() -> bool:
    if get_tree() == null:
        return false
    _garage = get_node_or_null("/root/VehicleGarage")
    if _garage == null:
        return false

    var panel: Variant = _garage.get("_panel")
    if not panel is PanelContainer and _garage.has_method("_build_ui"):
        _garage.call("_build_ui")
        panel = _garage.get("_panel")
    if not panel is PanelContainer:
        return false

    if _garage.get("_remote") == null and _garage.has_method("_bind_remote_fleet"):
        _garage.call("_bind_remote_fleet")
    if not _primed and _garage.has_method("_populate"):
        _garage.call("_populate")

    _primed = true
    set_process(false)
    return true

func open_garage() -> bool:
    if not _prime():
        return false
    var panel: Variant = _garage.get("_panel")
    if not panel is PanelContainer:
        return false
    var panel_control := panel as PanelContainer
    var panel_size := Vector2(410.0, 320.0)
    panel_control.set_anchors_preset(Control.PRESET_CENTER)
    panel_control.size = panel_size
    panel_control.position = -panel_size * 0.5
    panel_control.visible = true
    return true

func close_garage() -> void:
    if _garage == null:
        _garage = get_node_or_null("/root/VehicleGarage")
    if _garage == null:
        return
    var panel: Variant = _garage.get("_panel")
    if panel is Control:
        (panel as Control).visible = false

func toggle_garage() -> bool:
    if not _prime():
        return false
    var panel: Variant = _garage.get("_panel")
    if not panel is PanelContainer:
        return false
    var panel_control := panel as PanelContainer
    if panel_control.visible:
        panel_control.visible = false
        return false
    return open_garage()

func _unhandled_key_input(event: InputEvent) -> void:
    if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_G:
        toggle_garage()
        var viewport := get_viewport()
        if viewport != null:
            viewport.set_input_as_handled()

static func access_contract() -> Dictionary:
    return {
        "autoload": "VehicleGarage",
        "controller_required_for_open": false,
        "keyboard_fallback": "G",
        "duplicate_garage": false,
        "hud_launcher": false,
    }
