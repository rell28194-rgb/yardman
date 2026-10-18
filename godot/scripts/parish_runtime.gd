extends Node
class_name YardmanParishRuntime

signal parish_changed(parish: String)
signal parish_data_reloaded(ready: bool)

const DATA_PATH := "res://data/parishes/manifest.json"
const UPDATE_INTERVAL := 0.25
const CANONICAL_PARISHES := [
    "Kingston",
    "St. Andrew",
    "St. Catherine",
    "Clarendon",
    "Manchester",
    "St. Elizabeth",
    "Westmoreland",
    "Hanover",
    "St. James",
    "Trelawny",
    "St. Ann",
    "St. Mary",
    "Portland",
    "St. Thomas",
]

var current_parish := ""
var _clock := 0.0
var _manifest: Dictionary = {}
var _parishes: Dictionary = {}
var _bounds: Array = []
var _ready_state := false

func _ready() -> void:
    reload_from_disk()

func reload_from_disk() -> bool:
    if not FileAccess.file_exists(DATA_PATH):
        _clear_data()
        parish_data_reloaded.emit(false)
        return false
    var payload: Variant = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH))
    if not payload is Dictionary:
        _clear_data()
        push_warning("Yardman parish runtime rejected invalid JSON")
        parish_data_reloaded.emit(false)
        return false
    var loaded := load_manifest(payload)
    parish_data_reloaded.emit(loaded)
    return loaded

func load_manifest(payload: Dictionary) -> bool:
    var records: Variant = payload.get("parishes", {})
    if not _valid_parish_set(records):
        _clear_data()
        return false
    var bounds := _compute_bounds(records)
    if bounds.size() != 4:
        _clear_data()
        return false
    _manifest = payload
    _parishes = records
    _bounds = bounds
    _ready_state = true
    return true

func is_ready() -> bool:
    return _ready_state

func parish_names() -> Array[String]:
    var result: Array[String] = []
    for parish in CANONICAL_PARISHES:
        result.append(str(parish))
    return result

func parish_at(x: float, z: float) -> String:
    if not _ready_state or not is_finite(x) or not is_finite(z):
        return ""
    if _bounds.size() == 4 and (x < float(_bounds[0]) or z < float(_bounds[1]) or x > float(_bounds[2]) or z > float(_bounds[3])):
        return ""
    var matches: Array[String] = []
    for parish_value in CANONICAL_PARISHES:
        var parish := str(parish_value)
        var polygons: Variant = _parishes.get(parish, [])
        if not polygons is Array:
            continue
        for raw_polygon in polygons:
            if not raw_polygon is Dictionary:
                continue
            var polygon_bounds: Variant = raw_polygon.get("bounds", [])
            if not polygon_bounds is Array or polygon_bounds.size() < 4:
                continue
            if x < float(polygon_bounds[0]) or z < float(polygon_bounds[1]) or x > float(polygon_bounds[2]) or z > float(polygon_bounds[3]):
                continue
            var rings: Variant = raw_polygon.get("rings", [])
            if rings is Array and polygon_contains(Vector2(x, z), rings):
                matches.append(parish)
                break
    return matches[0] if matches.size() == 1 else ""

func map_data() -> Dictionary:
    return {
        "ready": _ready_state,
        "parishes": _parishes,
        "bounds": _bounds.duplicate(),
        "current_parish": current_parish,
        "authority": str(_manifest.get("authority", "")),
        "source_sha256": str(_manifest.get("source_sha256", "")),
        "crs": str(_manifest.get("crs", "")),
    }

func set_current_parish(parish: String) -> bool:
    if not CANONICAL_PARISHES.has(parish):
        return false
    if parish == current_parish:
        return true
    current_parish = parish
    parish_changed.emit(parish)
    return true

func _process(delta: float) -> void:
    if not _ready_state:
        return
    _clock += delta
    if _clock < UPDATE_INTERVAL:
        return
    _clock = 0.0
    _sync_current_scene()

func _sync_current_scene() -> void:
    var tree := get_tree()
    if tree == null:
        return
    var scene: Node = tree.current_scene
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
    if active == null or not roads.has_method("local_to_world"):
        return
    var world: Variant = roads.call("local_to_world", active.position)
    if not world is PackedFloat64Array or world.size() < 3:
        return
    var parish := parish_at(float(world[0]), float(world[2]))
    if parish.is_empty():
        return
    if set_current_parish(parish):
        var scene_parish := str(scene.get("current_parish"))
        if scene_parish != parish:
            scene.set("current_parish", parish)

func _clear_data() -> void:
    _manifest = {}
    _parishes = {}
    _bounds = []
    _ready_state = false

func _valid_parish_set(records: Variant) -> bool:
    if not records is Dictionary or records.size() != CANONICAL_PARISHES.size():
        return false
    for parish_value in CANONICAL_PARISHES:
        var parish := str(parish_value)
        if not records.has(parish):
            return false
        var polygons: Variant = records[parish]
        if not polygons is Array or polygons.is_empty():
            return false
        for raw_polygon in polygons:
            if not _valid_polygon(raw_polygon):
                return false
    for name_value in records.keys():
        if not CANONICAL_PARISHES.has(str(name_value)):
            return false
    return true

func _valid_polygon(raw_polygon: Variant) -> bool:
    if not raw_polygon is Dictionary:
        return false
    var bounds: Variant = raw_polygon.get("bounds", [])
    var rings: Variant = raw_polygon.get("rings", [])
    if not bounds is Array or bounds.size() != 4 or not rings is Array or rings.is_empty():
        return false
    if not rings[0] is Array or rings[0].size() < 4:
        return false
    for value in bounds:
        if not is_finite(float(value)):
            return false
    for ring in rings:
        if not ring is Array or ring.size() < 4:
            return false
    return true

func _compute_bounds(records: Dictionary) -> Array:
    var min_x := INF
    var min_z := INF
    var max_x := -INF
    var max_z := -INF
    for parish_value in CANONICAL_PARISHES:
        var polygons: Variant = records.get(str(parish_value), [])
        if not polygons is Array:
            continue
        for raw_polygon in polygons:
            if not raw_polygon is Dictionary:
                continue
            var bounds: Variant = raw_polygon.get("bounds", [])
            if not bounds is Array or bounds.size() != 4:
                continue
            min_x = minf(min_x, float(bounds[0]))
            min_z = minf(min_z, float(bounds[1]))
            max_x = maxf(max_x, float(bounds[2]))
            max_z = maxf(max_z, float(bounds[3]))
    if not is_finite(min_x) or not is_finite(min_z) or not is_finite(max_x) or not is_finite(max_z):
        return []
    if max_x <= min_x or max_z <= min_z:
        return []
    return [min_x, min_z, max_x, max_z]

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
