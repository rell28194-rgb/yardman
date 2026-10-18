extends Control
class_name YardmanParishMapCanvas

const BACKGROUND := Color(0.035, 0.050, 0.044, 0.98)
const LAND := Color(0.16, 0.29, 0.21, 0.96)
const LAND_ACTIVE := Color(0.49, 0.40, 0.18, 0.98)
const BORDER := Color(0.84, 0.84, 0.73, 0.88)
const LABEL := Color(0.95, 0.93, 0.85)
const LABEL_MUTED := Color(0.72, 0.76, 0.70)

var _parishes: Dictionary = {}
var _bounds: Array = []
var current_parish := ""
var authority := ""

func configure(data: Dictionary) -> void:
    var parishes: Variant = data.get("parishes", {})
    var bounds: Variant = data.get("bounds", [])
    _parishes = parishes if parishes is Dictionary else {}
    _bounds = bounds.duplicate() if bounds is Array else []
    current_parish = str(data.get("current_parish", current_parish))
    authority = str(data.get("authority", ""))
    queue_redraw()

func set_current_parish(parish: String) -> void:
    if current_parish == parish:
        return
    current_parish = parish
    queue_redraw()

func parish_count() -> int:
    return _parishes.size()

static func world_to_canvas(point: Vector2, bounds: Array, area: Rect2) -> Vector2:
    if bounds.size() < 4:
        return area.get_center()
    var world_size := Vector2(maxf(1.0, float(bounds[2]) - float(bounds[0])), maxf(1.0, float(bounds[3]) - float(bounds[1])))
    var scale := minf(area.size.x / world_size.x, area.size.y / world_size.y)
    var fitted := world_size * scale
    var origin := area.position + (area.size - fitted) * 0.5
    return origin + Vector2(point.x - float(bounds[0]), point.y - float(bounds[1])) * scale

func _draw() -> void:
    var map_area := Rect2(Vector2(26.0, 72.0), Vector2(maxf(1.0, size.x - 52.0), maxf(1.0, size.y - 118.0)))
    draw_rect(Rect2(Vector2.ZERO, size), BACKGROUND, true)
    var font := ThemeDB.fallback_font
    draw_string(font, Vector2(28.0, 36.0), "JAMAICA · PARISH MAP", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 22, LABEL)
    if not current_parish.is_empty():
        draw_string(font, Vector2(28.0, 59.0), "Current parish: " + current_parish, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 15, LABEL_MUTED)
    if _parishes.is_empty() or _bounds.size() < 4:
        draw_string(font, map_area.get_center() - Vector2(150.0, 0.0), "Parish boundary data unavailable in this build", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 17, LABEL_MUTED)
        return

    var names: Array = _parishes.keys()
    names.sort()
    for name_value in names:
        var parish := str(name_value)
        var polygons: Variant = _parishes[name_value]
        if not polygons is Array:
            continue
        var fill := LAND_ACTIVE if parish == current_parish else LAND
        for raw_polygon in polygons:
            if not raw_polygon is Dictionary:
                continue
            var rings: Variant = raw_polygon.get("rings", [])
            if not rings is Array or rings.is_empty():
                continue
            var outer := _project_ring(rings[0], map_area)
            if outer.size() >= 3:
                draw_colored_polygon(outer, fill)
                draw_polyline(_closed_outline(outer), BORDER, 1.35, true)
            for hole_index in range(1, rings.size()):
                var hole := _project_ring(rings[hole_index], map_area)
                if hole.size() >= 3:
                    draw_colored_polygon(hole, BACKGROUND)
                    draw_polyline(_closed_outline(hole), BORDER, 1.0, true)

    for name_value in names:
        var parish := str(name_value)
        var label_position := _label_position(parish, map_area)
        if label_position == Vector2.INF:
            continue
        var label_size := font.get_string_size(parish, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13)
        draw_string(font, label_position - Vector2(label_size.x * 0.5, -5.0), parish, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13, LABEL)

    draw_string(font, Vector2(28.0, size.y - 18.0), "Administrative boundaries only · no roads or POI clutter", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13, LABEL_MUTED)

func _project_ring(raw_ring: Variant, map_area: Rect2) -> PackedVector2Array:
    var result := PackedVector2Array()
    if not raw_ring is Array:
        return result
    var limit := raw_ring.size()
    if limit > 1 and raw_ring[0] is Array and raw_ring[limit - 1] is Array:
        var first: Array = raw_ring[0]
        var last: Array = raw_ring[limit - 1]
        if first.size() >= 2 and last.size() >= 2 and is_equal_approx(float(first[0]), float(last[0])) and is_equal_approx(float(first[1]), float(last[1])):
            limit -= 1
    for index in range(limit):
        var point: Variant = raw_ring[index]
        if not point is Array or point.size() < 2:
            continue
        result.append(world_to_canvas(Vector2(float(point[0]), float(point[1])), _bounds, map_area))
    return result

func _closed_outline(points: PackedVector2Array) -> PackedVector2Array:
    var result := points.duplicate()
    if result.size() >= 2 and not result[0].is_equal_approx(result[result.size() - 1]):
        result.append(result[0])
    return result

func _label_position(parish: String, map_area: Rect2) -> Vector2:
    var polygons: Variant = _parishes.get(parish, [])
    if not polygons is Array:
        return Vector2.INF
    var best_area := -1.0
    var best_center := Vector2.INF
    for raw_polygon in polygons:
        if not raw_polygon is Dictionary:
            continue
        var bounds: Variant = raw_polygon.get("bounds", [])
        if not bounds is Array or bounds.size() < 4:
            continue
        var width := maxf(0.0, float(bounds[2]) - float(bounds[0]))
        var height := maxf(0.0, float(bounds[3]) - float(bounds[1]))
        var area := width * height
        if area <= best_area:
            continue
        best_area = area
        best_center = world_to_canvas(Vector2((float(bounds[0]) + float(bounds[2])) * 0.5, (float(bounds[1]) + float(bounds[3])) * 0.5), _bounds, map_area)
    return best_center
