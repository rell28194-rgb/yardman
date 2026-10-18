extends Node
class_name YardmanLocationTracker

const DATA_PATH := "res://data/places/manifest.json"
const PARISH_DATA_PATH := "res://data/parishes/manifest.json"
const UPDATE_INTERVAL := 0.25
const SEARCH_RADIUS_TILES := 4

const DETAIL_KINDS := {
    "square": 700.0,
    "neighbourhood": 1800.0,
    "quarter": 1800.0,
    "suburb": 3200.0,
    "locality": 1800.0,
}
const SETTLEMENT_KINDS := {
    "hamlet": 2600.0,
    "village": 5000.0,
    "town": 9000.0,
    "city": 16000.0,
    "parish_capital": 10000.0,
}

var _clock := 0.0
var _manifest: Dictionary = {}
var _tiles: Dictionary = {}
var _parish_manifest: Dictionary = {}
var _parishes: Dictionary = {}
var _tile_size := 4096.0
var _last_label := ""
var _last_parish := ""

func _ready() -> void:
    _load_places()
    _load_parishes()

func _load_places() -> void:
    if not FileAccess.file_exists(DATA_PATH):
        return
    var payload: Variant = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH))
    if not payload is Dictionary:
        push_warning("Yardman location index is invalid")
        return
    _manifest = payload
    _tiles = _manifest.get("tiles", {})
    _tile_size = maxf(1.0, float(_manifest.get("tile_size", 4096.0)))

func _load_parishes() -> void:
    _parish_manifest = {}
    _parishes = {}
    if not FileAccess.file_exists(PARISH_DATA_PATH):
        return
    var payload: Variant = JSON.parse_string(FileAccess.get_file_as_string(PARISH_DATA_PATH))
    if not payload is Dictionary:
        push_warning("Yardman parish boundary index is invalid")
        return
    var records: Variant = payload.get("parishes", {})
    if not records is Dictionary or records.size() != 14:
        push_warning("Yardman parish boundary index is incomplete")
        return
    _parish_manifest = payload
    _parishes = records

func _process(delta: float) -> void:
    _clock += delta
    if _clock >= UPDATE_INTERVAL:
        _clock = 0.0
        _update_location()
    _apply_cached_label()

func _apply_cached_label() -> void:
    if _last_label.is_empty():
        return
    var scene: Node = get_tree().current_scene
    if scene == null:
        return
    var hud: Variant = scene.get("hud")
    if hud != null:
        hud.call("set_status", {"parish": _last_label})

func _update_location() -> void:
    var scene: Node = get_tree().current_scene
    if scene == null:
        return
    var roads: Variant = scene.get("roads")
    var player: Variant = scene.get("player")
    var car: Variant = scene.get("car")
    if roads == null or player == null or car == null:
        return
    var active: Node3D = player as Node3D
    if bool(player.get("in_vehicle")):
        active = car as Node3D
    if active == null:
        return
    var world: Variant = roads.call("local_to_world", active.position)
    if not world is PackedFloat64Array or world.size() < 3:
        return
    var x := float(world[0])
    var z := float(world[2])
    var parish := _parish_at(x, z)
    # Never infer administrative truth from nearest road/parish anchors. When
    # polygon authority is unavailable, preserve an already-authoritative scene
    # parish if one exists; otherwise keep the location unresolved.
    if parish.is_empty():
        parish = str(scene.get("current_parish"))
    var place := _resolve_place(x, z, parish)
    var label := _compose_label(place, parish)
    if label.is_empty():
        label = parish if not parish.is_empty() else "Jamaica"

    if not parish.is_empty() and parish != _last_parish:
        scene.set("current_parish", parish)
        _last_parish = parish
    _last_label = label

func _parish_at(x: float, z: float) -> String:
    if not is_finite(x) or not is_finite(z) or _parishes.is_empty():
        return ""
    var matches: Array[String] = []
    var names: Array = _parishes.keys()
    names.sort()
    for name_value in names:
        var name := str(name_value)
        var polygons: Variant = _parishes[name_value]
        if not polygons is Array:
            continue
        for raw_polygon in polygons:
            if not raw_polygon is Dictionary:
                continue
            var bounds: Variant = raw_polygon.get("bounds", [])
            if not bounds is Array or bounds.size() < 4:
                continue
            if x < float(bounds[0]) or z < float(bounds[1]) or x > float(bounds[2]) or z > float(bounds[3]):
                continue
            var rings: Variant = raw_polygon.get("rings", [])
            if rings is Array and polygon_contains(Vector2(x, z), rings):
                matches.append(name)
                break
    return matches[0] if matches.size() == 1 else ""

static func point_in_ring(point: Vector2, ring: Array) -> bool:
    if ring.size() < 3:
        return false
    var inside := false
    var j := ring.size() - 1
    for i in range(ring.size()):
        var current: Variant = ring[i]
        var previous: Variant = ring[j]
        if not current is Array or not previous is Array or current.size() < 2 or previous.size() < 2:
            j = i
            continue
        var a := Vector2(float(current[0]), float(current[1]))
        var b := Vector2(float(previous[0]), float(previous[1]))
        var cross := (point.x - a.x) * (b.y - a.y) - (point.y - a.y) * (b.x - a.x)
        var dot := (point.x - a.x) * (point.x - b.x) + (point.y - a.y) * (point.y - b.y)
        if absf(cross) <= 0.0001 and dot <= 0.0001:
            return true
        if (a.y > point.y) != (b.y > point.y):
            var x_at_y := (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
            if point.x < x_at_y:
                inside = not inside
        j = i
    return inside

static func polygon_contains(point: Vector2, rings: Array) -> bool:
    if rings.is_empty() or not rings[0] is Array or not point_in_ring(point, rings[0]):
        return false
    for i in range(1, rings.size()):
        if rings[i] is Array and point_in_ring(point, rings[i]):
            return false
    return true

func _resolve_place(x: float, z: float, parish: String) -> Dictionary:
    # Administrative ambiguity must stay ambiguous. A nearby place is not valid
    # evidence for selecting a parish, so do not use place records until parish
    # authority has been resolved independently.
    if parish.is_empty() or _tiles.is_empty():
        return {"detail": {}, "settlement": {}, "parish": parish}
    var tx := int(floor(x / _tile_size))
    var tz := int(floor(z / _tile_size))
    var best_detail: Dictionary = {}
    var best_detail_distance := INF
    var best_settlement: Dictionary = {}
    var best_settlement_distance := INF
    for dz in range(-SEARCH_RADIUS_TILES, SEARCH_RADIUS_TILES + 1):
        for dx in range(-SEARCH_RADIUS_TILES, SEARCH_RADIUS_TILES + 1):
            var key := "%d:%d" % [tx + dx, tz + dz]
            var records: Variant = _tiles.get(key, [])
            if not records is Array:
                continue
            for raw in records:
                if not raw is Dictionary:
                    continue
                # Runtime place labels require exact parish authority. Empty,
                # guessed, or cross-border records are intentionally excluded.
                if str(raw.get("parish", "")) != parish:
                    continue
                var kind := str(raw.get("kind", ""))
                var distance := Vector2(x - float(raw.get("x", 0.0)), z - float(raw.get("z", 0.0))).length()
                if DETAIL_KINDS.has(kind) and distance <= float(DETAIL_KINDS[kind]) and distance < best_detail_distance:
                    best_detail = raw
                    best_detail_distance = distance
                if SETTLEMENT_KINDS.has(kind) and distance <= float(SETTLEMENT_KINDS[kind]) and distance < best_settlement_distance:
                    best_settlement = raw
                    best_settlement_distance = distance
    return {"detail": best_detail, "settlement": best_settlement, "parish": parish}

func _compose_label(place: Dictionary, parish: String) -> String:
    var pieces: Array[String] = []
    var detail: Variant = place.get("detail", {})
    var settlement: Variant = place.get("settlement", {})
    if detail is Dictionary and not detail.is_empty():
        pieces.append(str(detail.get("name", "")))
    if settlement is Dictionary and not settlement.is_empty():
        var settlement_name := str(settlement.get("name", ""))
        if not settlement_name.is_empty() and (pieces.is_empty() or settlement_name != pieces[0]):
            pieces.append(settlement_name)
    if not parish.is_empty() and (pieces.is_empty() or parish != pieces.back()):
        pieces.append(parish)
    var clean: Array[String] = []
    for piece in pieces:
        if not piece.is_empty():
            clean.append(piece)
    return " · ".join(clean)