extends Node
class_name YardmanBeta1ExactRoadSurfaceAudioRuntime

# Optional private-pack surface variety. Exact surface identity comes from the
# persistent OSM road graph already packaged with Yardman; no random material
# assignment and no road/world geometry mutation is allowed here. The runtime
# only replaces the existing road-loop cache entries, so GameAudio remains at
# its established four-player voice budget.
const References = preload("res://scripts/reference_assets.gd")
const GameAudio = preload("res://scripts/game_audio.gd")
const OPTIONAL_FILES := {
    "asphalt": "road_asphalt_roll_loop.wav",
    "concrete": "road_concrete_roll_loop.wav",
    "cobblestone": "road_cobblestone_roll_loop.wav",
    "gravel": "road_gravel_roll_loop.wav",
}
const PROBE_INTERVAL_S := 0.20

var _roads
var _car: Node3D
var _audio
var _clock := 0.0
var _bound := false
var _streams: Dictionary = {}
var _default_road: AudioStream
var _default_gravel: AudioStream
var _active_family := ""

func _ready() -> void:
    call_deferred("_try_bind")

func _process(delta: float) -> void:
    if not _bound:
        _clock += delta
        if _clock >= PROBE_INTERVAL_S:
            _clock = 0.0
            _try_bind()
        return
    _clock += delta
    if _clock < PROBE_INTERVAL_S:
        return
    _clock = 0.0
    _probe()

func _exit_tree() -> void:
    _restore_defaults()

func _try_bind() -> void:
    var root := get_parent()
    if root == null:
        return
    _roads = root.get_node_or_null("JamaicaRoadStreamer")
    _car = root.get_node_or_null("RoadQA") as Node3D
    _audio = root.get_node_or_null("GameAudio")
    if _roads == null or _car == null or _audio == null:
        return
    if GameAudio._stream_cache.is_empty():
        return
    _default_road = GameAudio._stream_cache.get("road") as AudioStream
    _default_gravel = GameAudio._stream_cache.get("road_gravel") as AudioStream
    if _default_road == null or _default_gravel == null:
        return
    for family: String in OPTIONAL_FILES:
        var stream := References.audio(str(OPTIONAL_FILES[family]), true)
        if stream != null:
            _streams[family] = stream
    _bound = true
    _probe()

func _probe() -> void:
    if _roads == null or not is_instance_valid(_roads) or _car == null or not is_instance_valid(_car):
        _bound = false
        return
    var world_value: Variant = _roads.call("local_to_world", _car.position)
    if not world_value is PackedFloat64Array:
        _apply_family("offroad")
        return
    var world := world_value as PackedFloat64Array
    if world.size() < 3:
        _apply_family("offroad")
        return
    var surface_value: Variant = _roads.call("road_surface_at", world[0], world[2])
    if not surface_value is Dictionary:
        _apply_family("offroad")
        return
    var surface: Dictionary = surface_value
    if not bool(surface.get("found", false)):
        _apply_family("offroad")
        return
    var broad := str(surface.get("surface", "paved"))
    var edge_id := str(surface.get("edge_id", ""))
    var raw_surface := ""
    if not edge_id.is_empty() and _roads.get("graph") != null:
        var edge_value: Variant = _roads.graph.get_edge(edge_id)
        if edge_value is Dictionary:
            raw_surface = str((edge_value as Dictionary).get("surface", ""))
    _apply_family(normalize_surface(raw_surface, broad))

func _apply_family(family: String) -> void:
    if family == _active_family:
        return
    _active_family = family
    if _default_road != null:
        GameAudio._stream_cache["road"] = _default_road
    if _default_gravel != null:
        GameAudio._stream_cache["road_gravel"] = _default_gravel
    var stream := _streams.get(family) as AudioStream
    if stream == null:
        return
    var key := cache_key_for_family(family)
    if not key.is_empty():
        GameAudio._stream_cache[key] = stream

func _restore_defaults() -> void:
    if _default_road != null and not GameAudio._stream_cache.is_empty():
        GameAudio._stream_cache["road"] = _default_road
    if _default_gravel != null and not GameAudio._stream_cache.is_empty():
        GameAudio._stream_cache["road_gravel"] = _default_gravel
    _active_family = ""

static func normalize_surface(raw_surface: String, broad_surface: String) -> String:
    var raw := raw_surface.strip_edges().to_lower()
    if ";" in raw:
        raw = raw.split(";", false, 1)[0]
    if raw in ["asphalt", "chipseal", "tarmac"]:
        return "asphalt"
    if raw in ["concrete", "concrete:lanes", "concrete:plates"]:
        return "concrete"
    if raw in ["cobblestone", "unhewn_cobblestone", "sett", "paving_stones"]:
        return "cobblestone"
    if raw in ["gravel", "fine_gravel", "compacted"]:
        return "gravel"
    if raw in ["dirt", "earth", "ground", "mud", "sand", "unpaved"]:
        return "unpaved"
    if broad_surface == "unpaved":
        return "unpaved"
    if broad_surface == "paved":
        return "paved"
    return "offroad"

static func cache_key_for_family(family: String) -> String:
    if family in ["asphalt", "concrete", "cobblestone", "paved"]:
        return "road"
    if family in ["gravel", "unpaved"]:
        return "road_gravel"
    return ""

static func asset_contract() -> Dictionary:
    return {
        "files": OPTIONAL_FILES.duplicate(),
        "source_truth": "persistent OSM road graph edge.surface",
        "probe_hz": 5,
        "voice_budget": 4,
        "extra_players": 0,
        "geometry_mutation": false,
        "road_class_mutation": false,
        "random_surface_assignment": false,
        "asset_absent_fallback": true,
        "cobblestone_private_media_optional": true,
    }
