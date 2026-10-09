extends Control
class_name YardmanTouchControls

var driving := true
var fingers: Dictionary = {}
var look_delta := Vector2.ZERO
var _panels: Dictionary = {}
var _labels: Dictionary = {}

func _ready() -> void:
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    for zone in ["left", "right", "brake", "gas"]:
        var panel := Panel.new()
        panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
        var style := StyleBoxFlat.new()
        style.bg_color = Color(0.03, 0.05, 0.07, 0.70)
        style.border_color = Color(0.75, 0.85, 0.46, 0.9)
        style.set_border_width_all(2)
        style.set_corner_radius_all(16)
        panel.add_theme_stylebox_override("panel", style)
        add_child(panel)
        var label := Label.new()
        label.mouse_filter = Control.MOUSE_FILTER_IGNORE
        label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
        label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
        label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
        label.add_theme_font_size_override("font_size", 25)
        panel.add_child(label)
        _panels[zone] = panel
        _labels[zone] = label

func _process(_delta: float) -> void:
    for zone in _panels:
        var rect := _zone_rect(zone)
        _panels[zone].position = rect.position
        _panels[zone].size = rect.size
        _panels[zone].modulate = Color(1.0, 1.0, 0.75) if held(zone) else Color.WHITE
    _labels.left.text = "◀"
    _labels.right.text = "▶"
    _labels.brake.text = "BRAKE" if driving else "BACK"
    _labels.gas.text = "GAS" if driving else "FORWARD"

func _input(event: InputEvent) -> void:
    if event is InputEventScreenTouch:
        if event.pressed:
            fingers[event.index] = _zone_at(event.position)
        else:
            fingers.erase(event.index)
    elif event is InputEventScreenDrag:
        var previous: String = str(fingers.get(event.index, ""))
        if previous == "look":
            look_delta += event.relative
        else:
            fingers[event.index] = _zone_at(event.position)
    elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.device >= 0:
        if event.pressed:
            fingers[-1] = _zone_at(event.position)
        else:
            fingers.erase(-1)
    elif event is InputEventMouseMotion and fingers.get(-1, "") == "look" and event.device >= 0:
        look_delta += event.relative

func _notification(what: int) -> void:
    if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
        fingers.clear()

func held(zone: String) -> bool:
    return fingers.values().has(zone)

func throttle() -> float:
    return float(int(held("gas")) - int(held("brake")))

func steering() -> float:
    return float(int(held("right")) - int(held("left")))

func consume_look() -> Vector2:
    var value := look_delta
    look_delta = Vector2.ZERO
    return value

func _zone_at(point: Vector2) -> String:
    for zone in ["left", "right", "brake", "gas"]:
        if _zone_rect(zone).has_point(point):
            return zone
    return "look" if point.y > get_viewport_rect().size.y * 0.25 else ""

func _zone_rect(zone: String) -> Rect2:
    var viewport_size := get_viewport_rect().size
    var x := 26.0
    if zone == "right":
        x = 164.0
    elif zone == "brake":
        x = viewport_size.x - 302.0
    elif zone == "gas":
        x = viewport_size.x - 164.0
    return Rect2(Vector2(x, viewport_size.y - 156.0), Vector2(126.0, 126.0))
