extends Node
class_name YardmanWeatherCycleRuntime

const STATE_PATH := "user://yardman/weather-cycle.json"
const SLOT_HOURS := 3.0
const MODES := ["clear", "showers", "rain", "storm"]

var day_index := 0
var current_mode := "clear"
var current_slot := -1
var current_parish := ""
var _last_hour := 0.0
var _have_clock_sample := false
var _loaded_mode := ""
var _dirty := false
var _update_clock := 999.0
const UPDATE_INTERVAL := 0.50

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    _load_state()

func _process(delta: float) -> void:
    _update_clock += delta
    if _update_clock < UPDATE_INTERVAL:
        return
    _update_clock = 0.0
    var scene := get_tree().current_scene
    if scene == null:
        return
    var hour_value = scene.get("day_hour")
    if not (hour_value is float or hour_value is int):
        return
    var hour := fmod(float(hour_value) + 24.0, 24.0)
    if not _have_clock_sample:
        _last_hour = hour
        _have_clock_sample = true
    elif _last_hour >= 22.0 and hour < 2.0:
        day_index += 1
        _dirty = true
    _last_hour = hour

    var parish := str(scene.get("current_parish"))
    if parish.is_empty():
        parish = "Jamaica"
    var slot := slot_for_hour(hour)
    if slot == current_slot and parish == current_parish and not current_mode.is_empty():
        if _dirty:
            _save_state()
        return

    var scheduled := scheduled_mode(day_index, hour, parish)
    var atmosphere := get_node_or_null("/root/AtmosphereFX")
    if atmosphere != null and atmosphere.has_method("set_weather"):
        var first_apply := current_slot < 0
        var restore_match := first_apply and not _loaded_mode.is_empty() and _loaded_mode == scheduled
        atmosphere.call("set_weather", scheduled, restore_match)
    current_mode = scheduled
    current_slot = slot
    current_parish = parish
    _dirty = true
    _save_state()

static func slot_for_hour(hour: float) -> int:
    var normalized := fmod(hour + 24.0, 24.0)
    return clampi(int(floor(normalized / SLOT_HOURS)), 0, 7)

static func climate_weights(parish: String, hour: float) -> Dictionary:
    # Gameplay climate bias only: geography remains sourced elsewhere. Eastern
    # and high-rainfall parishes get more wet slots; south/central dry areas get
    # fewer. The scheduler is deterministic, not a claim of live meteorology.
    var weights := {"clear": 0.48, "showers": 0.28, "rain": 0.19, "storm": 0.05}
    var wet_east := parish in ["Portland", "St. Mary", "St. Thomas", "St. Andrew"]
    var drier_south := parish in ["St. Elizabeth", "Clarendon", "Manchester"]
    if wet_east:
        weights.clear = 0.35
        weights.showers = 0.32
        weights.rain = 0.25
        weights.storm = 0.08
    elif drier_south:
        weights.clear = 0.59
        weights.showers = 0.24
        weights.rain = 0.14
        weights.storm = 0.03

    var h := fmod(hour + 24.0, 24.0)
    if h >= 12.0 and h < 18.0:
        weights.clear = maxf(0.20, float(weights.clear) - 0.10)
        weights.showers = float(weights.showers) + 0.065
        weights.rain = float(weights.rain) + 0.028
        weights.storm = float(weights.storm) + 0.007
    elif h >= 0.0 and h < 6.0:
        weights.clear = float(weights.clear) + 0.08
        weights.showers = maxf(0.05, float(weights.showers) - 0.04)
        weights.rain = maxf(0.04, float(weights.rain) - 0.03)
        weights.storm = maxf(0.01, float(weights.storm) - 0.01)
    return normalize_weights(weights)

static func normalize_weights(weights: Dictionary) -> Dictionary:
    var total := 0.0
    for mode in MODES:
        total += maxf(0.0, float(weights.get(mode, 0.0)))
    if total <= 0.0001:
        return {"clear": 1.0, "showers": 0.0, "rain": 0.0, "storm": 0.0}
    var result := {}
    for mode in MODES:
        result[mode] = maxf(0.0, float(weights.get(mode, 0.0))) / total
    return result

static func deterministic_unit(day_value: int, slot: int, parish: String) -> float:
    var key := "%d|%d|%s|yardman-weather-v1" % [day_value, slot, parish]
    var hashed: int = int(key.hash())
    var positive: int = absi(hashed) if hashed != -9223372036854775808 else 0
    return float(positive % 1000003) / 1000002.0

static func choose_mode(unit: float, weights: Dictionary) -> String:
    var cursor := 0.0
    var value := clampf(unit, 0.0, 1.0)
    for mode in MODES:
        cursor += float(weights.get(mode, 0.0))
        if value <= cursor + 0.000001:
            return mode
    return "clear"

static func scheduled_mode(day_value: int, hour: float, parish: String) -> String:
    var slot := slot_for_hour(hour)
    return choose_mode(deterministic_unit(day_value, slot, parish), climate_weights(parish, hour))

func _load_state() -> void:
    if not FileAccess.file_exists(STATE_PATH):
        return
    var payload = JSON.parse_string(FileAccess.get_file_as_string(STATE_PATH))
    if not payload is Dictionary:
        return
    day_index = maxi(0, int(payload.get("day_index", 0)))
    var mode := str(payload.get("mode", ""))
    if mode in MODES:
        _loaded_mode = mode
        current_mode = mode

func _save_state() -> void:
    if not _dirty:
        return
    var directory := ProjectSettings.globalize_path(STATE_PATH.get_base_dir())
    if DirAccess.make_dir_recursive_absolute(directory) != OK:
        return
    var file := FileAccess.open(STATE_PATH, FileAccess.WRITE)
    if file == null:
        return
    file.store_string(JSON.stringify({
        "schema": 1,
        "day_index": day_index,
        "mode": current_mode,
        "slot": current_slot,
        "parish": current_parish,
    }))
    file.close()
    _dirty = false

func runtime_snapshot() -> Dictionary:
    return {
        "day_index": day_index,
        "mode": current_mode,
        "slot": current_slot,
        "parish": current_parish,
    }
