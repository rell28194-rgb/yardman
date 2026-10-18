extends RefCounted
class_name YardmanVehicleFleetRegistry

const DATA_PATHS := [
    "res://data/vehicle_fleet_runtime.json",
    "res://data/vehicle_fleet_supplemental.json",
]
static var _entries: Dictionary = {}
static var _ids: Array = []
static var _loaded := false

static func _ensure_loaded() -> void:
    if _loaded:
        return
    _loaded = true
    for data_path in DATA_PATHS:
        if not FileAccess.file_exists(data_path):
            push_error("Yardman fleet runtime registry is missing: %s" % data_path)
            continue
        var parsed = JSON.parse_string(FileAccess.get_file_as_string(data_path))
        if not parsed is Dictionary or int(parsed.get("format_version", 0)) != 1:
            push_error("Yardman fleet runtime registry is invalid: %s" % data_path)
            continue
        for raw_entry in parsed.get("vehicles", []):
            if not raw_entry is Dictionary:
                continue
            var entry: Dictionary = raw_entry
            var vehicle_id := str(entry.get("id", ""))
            if vehicle_id.is_empty():
                continue
            if _entries.has(vehicle_id):
                push_error("Yardman fleet runtime registry duplicates selector %s" % vehicle_id)
                continue
            _entries[vehicle_id] = entry.duplicate(true)
            _ids.append(vehicle_id)

static func has(vehicle_id: String) -> bool:
    _ensure_loaded()
    return _entries.has(vehicle_id)

static func entry(vehicle_id: String) -> Dictionary:
    _ensure_loaded()
    return _entries[vehicle_id].duplicate(true) if _entries.has(vehicle_id) else {}

static func ids() -> Array:
    _ensure_loaded()
    return _ids.duplicate()

static func count() -> int:
    _ensure_loaded()
    return _entries.size()
