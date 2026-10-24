extends Control
class_name YardmanParishNavigation

const MANIFEST_PATH := "res://data/parishes/manifest.json"
const EXPECTED_PARISH_COUNT := 14
const MAP_BACKGROUND := Color(0.025, 0.038, 0.032, 0.985)
const MAP_LAND := Color(0.10, 0.18, 0.13, 0.96)
const MAP_ACTIVE := Color(0.24, 0.48, 0.31, 0.96)
const MAP_LINE := Color(0.86, 0.86, 0.75, 0.92)
const MAP_MUTED := Color(0.64, 0.69, 0.63)
const MAP_GOLD := Color(0.91, 0.71, 0.36)

var map_open := false
var _main: Node
var _hud: Control
var _touch
var _parishes: Dictionary = {}
var _parish_names: Array[String] = []
var _world_bounds := Rect2()
var _player_world := Vector2.ZERO
var _lookup_clock := 0.0
var _map_button: Button
var _bound := false

func _ready() -> void:
    _main = get_parent()
    process_physics_priority = -100
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    call_deferred("_bind_runtime")

func _bind_runtime() -> void:
    if _bound:
        return
    if _main == null:
        return
    _hud = _main.get("hud") as Control
    _touch = _main.get("touch")
    var roads = _main.get("roads")
    if _hud == null or _touch == null or roads == null:
        call_deferred("_bind_runtime")
        return
    if not _load_manifest():
        return
    reparent(_hud, false)
    set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    _map_button = Button.new()
    _map_button.name = "ParishMapButton"
    _map_button.text = "MAP"
    _map_button.tooltip_text = "Parish map · M"
    _map_button.focus_mode = Control.FOCUS_NONE
    _map_button.custom_minimum_size = Vector2(58.0, 44.0)
    _map_button.pressed.connect(func() -> void: set_map_open(not map_open))
    add_child(_map_button)
    if _hud.has_signal("menu_toggled"):
        var menu_cb := Callable(self, "_on_hud_menu_toggled")
        if not _hud.is_connected("menu_toggled", menu_cb):
            _hud.connect("menu_toggled", menu_cb)
    get_viewport().size_changed.connect(_relayout)
    _relayout()
    _bound = true
    _on_hud_menu_toggled(bool(_hud.get("menu_open")))
    queue_redraw()

func _on_hud_menu_toggled(open: bool) -> void:
    if _map_button == null:
        return
    # The parish map is a peer launcher to the HUD drawer, not part of it. It
    # must disappear while the drawer is open so it cannot cover the drawer's
    # close control or receive touches through the modal overlay.
    _map_button.visible = not open or map_open
    _map_button.disabled = open and not map_open
    _map_button.mouse_filter = Control.MOUSE_FILTER_IGNORE if open and not map_open else Control.MOUSE_FILTER_STOP

func _load_manifest() -> bool:
    if not FileAccess.file_exists(MANIFEST_PATH):
        push_error("Yardman parish manifest missing: " + MANIFEST_PATH)
        return false
    var payload = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
    if not payload is Dictionary:
        push_error("Yardman parish manifest is invalid JSON")
        return false
    var parish_data = payload.get("parishes", {})
    if not parish_data is Dictionary or parish_data.size() != EXPECTED_PARISH_COUNT:
        push_error("Yardman parish manifest must contain exactly 14 authoritative parishes")
        return false
    _parishes = parish_data
    _parish_names.clear()
    var minimum := Vector2(INF, INF)
    var maximum := Vector2(-INF, -INF)
    for parish_value in _parishes.keys():
        var parish := str(parish_value)
        _parish_names.append(parish)
        var polygons = _parishes[parish]
        if not polygons is Array or polygons.is_empty():
            push_error("Yardman parish has no polygon geometry: " + parish)
            return false
        for polygon in polygons:
            if not polygon is Dictionary:
                continue
            var bounds = polygon.get("bounds", [])
            if bounds is Array and bounds.size() >= 4:
                minimum.x = minf(minimum.x, float(bounds[0]))
                minimum.y = minf(minimum.y, float(bounds[1]))
                maximum.x = maxf(maximum.x, float(bounds[2]))
                maximum.y = maxf(maximum.y, float(bounds[3]))
    _parish_names.sort()
    if not is_finite(minimum.x) or not is_finite(minimum.y) or not is_finite(maximum.x) or not is_finite(maximum.y):
        push_error("Yardman parish manifest has no finite bounds")
        return false
    _world_bounds = Rect2(minimum, maximum - minimum)
    print("YARDMAN_PARISH_NAVIGATION authoritative_parishes=%d" % _parish_names.size())
    return true

func _physics_process(delta: float) -> void:
    if not _bound or _main == null:
        return
    var roads = _main.get("roads")
    var player = _main.get("player")
    var car = _main.get("car")
    if roads == null or player == null or car == null:
        return
    var active: Node3D = car if bool(player.get("in_vehicle")) else player
    var world: PackedFloat64Array = roads.local_to_world(active.position)
    if world.size() < 3:
        return
    _player_world = Vector2(float(world[0]), float(world[2]))
    _lookup_clock += delta
    if _lookup_clock >= 0.15:
        _lookup_clock = 0.0
        var parish := parish_at(_player_world)
        if not parish.is_empty() and parish != str(_main.get("current_parish")):
            _main.set("current_parish", parish)
            if _hud != null and _hud.has_method("select_parish"):
                _hud.call("select_parish", parish)
    if map_open:
        queue_redraw()

func parish_at(point: Vector2) -> String:
    for parish in _parish_names:
        var polygons = _parishes.get(parish, [])
        for polygon in polygons:
            if not polygon is Dictionary:
                continue
            var bounds = polygon.get("bounds", [])
            if not _point_in_bounds(point, bounds):
                continue
            var rings = polygon.get("rings", [])
            if not rings is Array or rings.is_empty() or not _point_in_ring(point, rings[0]):
                continue
            var inside_hole := false
            for ring_index in range(1, rings.size()):
                if _point_in_ring(point, rings[ring_index]):
                    inside_hole = true
                    break
            if not inside_hole:
                return parish
    return ""

func _point_in_bounds(point: Vector2, bounds: Variant) -> bool:
    if not bounds is Array or bounds.size() < 4:
        return false
    return point.x >= float(bounds[0]) and point.y >= float(bounds[1]) and point.x <= float(bounds[2]) and point.y <= float(bounds[3])

func _point_in_ring(point: Vector2, ring: Variant) -> bool:
    if not ring is Array or ring.size() < 3:
        return false
    var inside := false
    var previous: int = ring.size() - 1
    for index in range(ring.size()):
        var a = ring[index]
        var b = ring[previous]
        if a is Array and b is Array and a.size() >= 2 and b.size() >= 2:
            var ax := float(a[0])
            var az := float(a[1])
            var bx := float(b[0])
            var bz := float(b[1])
            if (az > point.y) != (bz > point.y):
                var crossing_x := (bx - ax) * (point.y - az) / (bz - az) + ax
                if point.x < crossing_x:
                    inside = not inside
        previous = index
    return inside

func set_map_open(value: bool) -> void:
    if not _bound or map_open == value:
        return
    map_open = value
    if map_open:
        if bool(_hud.get("menu_open")) and _hud.has_method("set_menu_open"):
            _hud.call("set_menu_open", false)
        _hud.set("menu_open", true)
        _hud.set_process_unhandled_key_input(false)
        _touch.set("input_enabled", false)
        if _touch.has_method("clear_input"):
            _touch.call("clear_input")
        mouse_filter = Control.MOUSE_FILTER_STOP
        _map_button.visible = true
        _map_button.disabled = false
        _map_button.mouse_filter = Control.MOUSE_FILTER_STOP
        _map_button.text = "×"
        _map_button.tooltip_text = "Close parish map · M / Escape"
    else:
        _hud.set("menu_open", false)
        _hud.set_process_unhandled_key_input(true)
        _touch.set("input_enabled", true)
        mouse_filter = Control.MOUSE_FILTER_IGNORE
        _map_button.visible = true
        _map_button.disabled = false
        _map_button.mouse_filter = Control.MOUSE_FILTER_STOP
        _map_button.text = "MAP"
        _map_button.tooltip_text = "Parish map · M"
    queue_redraw()

func _unhandled_key_input(event: InputEvent) -> void:
    if not event is InputEventKey or not event.pressed or event.echo:
        return
    if event.physical_keycode == KEY_M or (map_open and event.physical_keycode == KEY_ESCAPE):
        set_map_open(not map_open if event.physical_keycode == KEY_M else false)
        get_viewport().set_input_as_handled()

func _relayout() -> void:
    if _map_button == null:
        return
    var dimensions := get_viewport_rect().size
    _map_button.position = Vector2(dimensions.x - 142.0, 18.0)
    _map_button.size = Vector2(62.0, 44.0)

func _draw() -> void:
    if not map_open or _parishes.is_empty():
        return
    var dimensions := get_viewport_rect().size
    draw_rect(Rect2(Vector2.ZERO, dimensions), MAP_BACKGROUND, true)
    var font := ThemeDB.fallback_font
    draw_string(font, Vector2(34.0, 48.0), "JAMAICA · PARISHES", HORIZONTAL_ALIGNMENT_LEFT, -1, 25, Color(0.95, 0.93, 0.85))
    var current := str(_main.get("current_parish")) if _main != null else ""
    draw_string(font, Vector2(35.0, 76.0), "Current parish: " + current, HORIZONTAL_ALIGNMENT_LEFT, -1, 17, MAP_GOLD)
    var map_rect := _map_rect(dimensions)
    for parish in _parish_names:
        var polygons = _parishes.get(parish, [])
        var fill := MAP_ACTIVE if parish == current else MAP_LAND
        for polygon in polygons:
            if not polygon is Dictionary:
                continue
            var rings = polygon.get("rings", [])
            if not rings is Array or rings.is_empty():
                continue
            var outer := _mapped_ring(rings[0], map_rect)
            if outer.size() >= 3:
                draw_colored_polygon(outer, fill)
            for ring in rings:
                var line := _mapped_ring(ring, map_rect)
                if line.size() >= 2:
                    draw_polyline(line, MAP_GOLD if parish == current else MAP_LINE, 2.0 if parish == current else 1.1, true)
    for parish in _parish_names:
        var label_world := _parish_label_point(parish)
        var label_point := _world_to_map(label_world, map_rect)
        var label_size := font.get_string_size(parish, HORIZONTAL_ALIGNMENT_LEFT, -1, 12)
        draw_string(font, label_point - Vector2(label_size.x * 0.5, -4.0), parish, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.95, 0.93, 0.85))
    var player_point := _world_to_map(_player_world, map_rect)
    draw_circle(player_point, 7.0, Color(0.02, 0.03, 0.025, 0.95))
    draw_circle(player_point, 4.5, MAP_GOLD)
    draw_string(font, Vector2(35.0, dimensions.y - 26.0), "14 parishes · player position", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, MAP_MUTED)

func _map_rect(dimensions: Vector2) -> Rect2:
    var available := Rect2(Vector2(42.0, 100.0), Vector2(maxf(1.0, dimensions.x - 84.0), maxf(1.0, dimensions.y - 150.0)))
    var scale := minf(available.size.x / maxf(_world_bounds.size.x, 1.0), available.size.y / maxf(_world_bounds.size.y, 1.0))
    var size := _world_bounds.size * scale
    return Rect2(available.position + (available.size - size) * 0.5, size)

func _world_to_map(point: Vector2, map_rect: Rect2) -> Vector2:
    var normalized := Vector2(
        (point.x - _world_bounds.position.x) / maxf(_world_bounds.size.x, 1.0),
        (point.y - _world_bounds.position.y) / maxf(_world_bounds.size.y, 1.0))
    return map_rect.position + normalized * map_rect.size

func _mapped_ring(ring: Variant, map_rect: Rect2) -> PackedVector2Array:
    var result := PackedVector2Array()
    if not ring is Array:
        return result
    for raw in ring:
        if raw is Array and raw.size() >= 2:
            result.append(_world_to_map(Vector2(float(raw[0]), float(raw[1])), map_rect))
    return result

func _parish_label_point(parish: String) -> Vector2:
    var minimum := Vector2(INF, INF)
    var maximum := Vector2(-INF, -INF)
    for polygon in _parishes.get(parish, []):
        if not polygon is Dictionary:
            continue
        var bounds = polygon.get("bounds", [])
        if bounds is Array and bounds.size() >= 4:
            minimum.x = minf(minimum.x, float(bounds[0]))
            minimum.y = minf(minimum.y, float(bounds[1]))
            maximum.x = maxf(maximum.x, float(bounds[2]))
            maximum.y = maxf(maximum.y, float(bounds[3]))
    return (minimum + maximum) * 0.5 if is_finite(minimum.x) else Vector2.ZERO
