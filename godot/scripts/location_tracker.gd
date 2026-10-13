extends Node
class_name YardmanLocationTracker

const DATA_PATH := "res://data/places/manifest.json"
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
var _tile_size := 4096.0
var _last_label := ""
var _last_parish := ""

func _ready() -> void:
    _load_places()

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

func _process(delta: float) -> void:
    _clock += delta
    if _clock < UPDATE_INTERVAL:
        return
    _clock = 0.0
    _update_location()

func _update_location() -> void:
    var scene: Node = get_tree().current_scene
    if scene == null:
        return
    var roads: Variant = scene.get("roads")
    var player: Variant = scene.get("player")
    var car: Variant = scene.get("car")
    var hud: Variant = scene.get("hud")
    if roads == null or player == null or car == null or hud == null:
        return
    var active: Node3D = player as Node3D
    if bool(player.get("in_vehicle")):
        active = car as Node3D
    if active == null:
        return
    var world: Variant = roads.call("local_to_world", active.position)
    if not world is PackedFloat64Array or world.size() < 3:
        return
    var x: float = float(world[0])
    var z: float = float(world[2])
    var parish: String = _nearest_parish(roads, x, z)
    if parish.is_empty():
        parish = str(scene.get("current_parish"))
    var place: Dictionary = _resolve_place(x, z, parish)
    var label: String = _compose_label(place, parish)
    if label.is_empty():
        label = parish if not parish.is_empty() else "Jamaica"

    # Keep gameplay recovery/travel state on a real parish, while the HUD gets
    # the more precise town/neighbourhood/square label.
    if not parish.is_empty() and parish != _last_parish:
        scene.set("current_parish", parish)
        _last_parish = parish
    if label != _last_label:
        _last_label = label
    hud.call("set_status", {"parish": label})

func _nearest_parish(roads: Variant, x: float, z: float) -> String:
    var road_manifest: Variant = roads.get("manifest")
    if not road_manifest is Dictionary:
        return ""
    var anchors: Variant = road_manifest.get("parish_anchors", {})
    if not anchors is Dictionary:
        return ""
    var best: String = ""
    var best_distance: float = INF
    for name in anchors:
        var raw: Variant = anchors[name]
        if not raw is Dictionary:
            continue
        var position: Variant = raw.get("road_position", [])
        var ax: float = float(raw.get("x", 0.0))
        var az: float = float(raw.get("z", 0.0))
        if position is Array and position.size() >= 3:
            ax = float(position[0])
            az = float(position[2])
        var distance: float = Vector2(x - ax, z - az).length_squared()
        if distance < best_distance:
            best_distance = distance
            best = str(name)
    return best

func _resolve_place(x: float, z: float, parish: String) -> Dictionary:
    if _tiles.is_empty():
        return {}
    var tx: int = int(floor(x / _tile_size))
    var tz: int = int(floor(z / _tile_size))
    var best_detail: Dictionary = {}
    var best_detail_distance: float = INF
    var best_settlement: Dictionary = {}
    var best_settlement_distance: float = INF
    for dz in range(-SEARCH_RADIUS_TILES, SEARCH_RADIUS_TILES + 1):
        for dx in range(-SEARCH_RADIUS_TILES, SEARCH_RADIUS_TILES + 1):
            var key: String = "%d:%d" % [tx + dx, tz + dz]
            var records: Variant = _tiles.get(key, [])
            if not records is Array:
                continue
            for raw in records:
                if not raw is Dictionary:
                    continue
                var kind: String = str(raw.get("kind", ""))
                var distance: float = Vector2(x - float(raw.get("x", 0.0)), z - float(raw.get("z", 0.0))).length()
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
        var settlement_name: String = str(settlement.get("name", ""))
        if not settlement_name.is_empty() and (pieces.is_empty() or settlement_name != pieces[0]):
            pieces.append(settlement_name)
    if not parish.is_empty() and (pieces.is_empty() or parish != pieces.back()):
        pieces.append(parish)
    var clean: Array[String] = []
    for piece in pieces:
        if not piece.is_empty():
            clean.append(piece)
    return " · ".join(clean)
