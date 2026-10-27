extends Node
class_name YardmanVehicleStatusHUDRuntime

const PANEL_WIDTH := 320.0
const PANEL_HEIGHT := 32.0
const BOTTOM_OFFSET := 91.0

var _layer: CanvasLayer
var _panel: PanelContainer
var _label: Label
var _last_text := ""

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    _layer = CanvasLayer.new()
    _layer.name = "VehicleStatusLayer"
    _layer.layer = 40
    add_child(_layer)

    _panel = PanelContainer.new()
    _panel.name = "VehicleStatusPanel"
    _panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _panel.custom_minimum_size = Vector2(PANEL_WIDTH, PANEL_HEIGHT)
    var panel_style := StyleBoxFlat.new()
    panel_style.bg_color = Color(0.035, 0.052, 0.045, 0.78)
    panel_style.border_color = Color(0.74, 0.72, 0.64, 0.20)
    panel_style.set_border_width_all(1)
    panel_style.set_corner_radius_all(8)
    panel_style.content_margin_left = 10
    panel_style.content_margin_right = 10
    panel_style.content_margin_top = 4
    panel_style.content_margin_bottom = 4
    _panel.add_theme_stylebox_override("panel", panel_style)
    _layer.add_child(_panel)

    _label = Label.new()
    _label.name = "VehicleStatusText"
    _label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    _label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
    _label.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _label.add_theme_font_size_override("font_size", 14)
    _label.add_theme_color_override("font_color", Color(0.95, 0.93, 0.85))
    _panel.add_child(_label)

    get_viewport().size_changed.connect(_relayout)
    _relayout()
    set_process(true)

func _exit_tree() -> void:
    var viewport := get_viewport()
    if viewport != null and viewport.size_changed.is_connected(_relayout):
        viewport.size_changed.disconnect(_relayout)

func _process(_delta: float) -> void:
    var game := get_tree().current_scene if get_tree() != null else null
    var text := status_text_for(game)
    if _panel != null:
        _panel.visible = not text.is_empty()
    if _label != null and text != _last_text:
        _last_text = text
        _label.text = text

func _relayout() -> void:
    if _panel == null:
        return
    var size := get_viewport().get_visible_rect().size
    _panel.position = Vector2((size.x - PANEL_WIDTH) * 0.5, size.y - BOTTOM_OFFSET)
    _panel.size = Vector2(PANEL_WIDTH, PANEL_HEIGHT)

func debug_text() -> String:
    return _label.text if _label != null else ""

static func status_text_for(game: Node) -> String:
    if game == null:
        return ""
    var vehicle = game.get("vehicle")
    var player = game.get("player")
    if vehicle == null or player == null:
        return ""
    var odometer_km := maxf(float(vehicle.get("odometer_m")) / 1000.0, 0.0)
    if player.get("in_vehicle") == true:
        var gear := ""
        if vehicle is RefCounted and vehicle.has_method("gear_label"):
            gear = str(vehicle.call("gear_label"))
        return "%s  •  ODO %.1f km" % [gear if not gear.is_empty() else "DRIVE", odometer_km]
    return "PARKED  •  ODO %.1f km" % odometer_km
