extends RefCounted
class_name YardmanVehicleFleetRegistry

const DATA_PATHS := [
    "res://data/vehicle_fleet_runtime.json",
    "res://data/vehicle_fleet_supplemental.json",
]
const CALIBRATION_PATH := "res://data/vehicle_fleet_calibration.json"
const OWNER_CONTRACT_PATH := "res://data/owner_fleet_pack_contract.json"
static var _entries: Dictionary = {}
static var _ids: Array = []
static var _allowed: Dictionary = {}
static var _loaded := false

static func _load_owner_contract() -> bool:
    if not FileAccess.file_exists(OWNER_CONTRACT_PATH):
        push_error("Yardman owner fleet contract is missing: %s" % OWNER_CONTRACT_PATH)
        return false
    var parsed = JSON.parse_string(FileAccess.get_file_as_string(OWNER_CONTRACT_PATH))
    if not parsed is Dictionary or int(parsed.get("format_version", 0)) != 1:
        push_error("Yardman owner fleet contract is invalid")
        return false
    var declared: Array = parsed.get("selectable_vehicle_ids", [])
    if declared.size() != int(parsed.get("selectable_vehicle_count", -1)) or declared.size() != 64:
        push_error("Yardman owner fleet contract must declare exactly 64 selectors")
        return false
    for raw_id in declared:
        var vehicle_id := str(raw_id)
        if vehicle_id.is_empty() or _allowed.has(vehicle_id):
            push_error("Yardman owner fleet contract contains an invalid/duplicate selector: %s" % vehicle_id)
            _allowed.clear()
            return false
        _allowed[vehicle_id] = true
    for raw_id in parsed.get("scrapped_vehicle_ids", []):
        if _allowed.has(str(raw_id)):
            push_error("Scrapped vehicle is present in owner fleet contract: %s" % str(raw_id))
            _allowed.clear()
            return false
    for raw_id in parsed.get("held_missing_vehicle_ids", []):
        if _allowed.has(str(raw_id)):
            push_error("Held vehicle is present in owner fleet contract: %s" % str(raw_id))
            _allowed.clear()
            return false
    return true

static func _ensure_loaded() -> void:
    if _loaded:
        return
    _loaded = true
    if not _load_owner_contract():
        return
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
            if vehicle_id.is_empty() or not _allowed.has(vehicle_id):
                continue
            if _entries.has(vehicle_id):
                push_error("Yardman fleet runtime registry duplicates selector %s" % vehicle_id)
                continue
            _entries[vehicle_id] = entry.duplicate(true)
            _ids.append(vehicle_id)
    _apply_calibration_overrides()
    # Crown is an explicit core profile in vehicle_catalog.gd, so the registry
    # must contain every other owner selector and no extras.
    var expected_registry_count := _allowed.size() - (1 if _allowed.has("toyota_crown") else 0)
    if _entries.size() != expected_registry_count:
        push_error("Yardman owner fleet registry is incomplete: expected=%d actual=%d" % [expected_registry_count, _entries.size()])

static func _apply_calibration_overrides() -> void:
    if not FileAccess.file_exists(CALIBRATION_PATH):
        push_error("Yardman fleet calibration registry is missing: %s" % CALIBRATION_PATH)
        return
    var parsed = JSON.parse_string(FileAccess.get_file_as_string(CALIBRATION_PATH))
    if not parsed is Dictionary or int(parsed.get("format_version", 0)) != 1:
        push_error("Yardman fleet calibration registry is invalid: %s" % CALIBRATION_PATH)
        return
    for raw_override in parsed.get("vehicles", []):
        if not raw_override is Dictionary:
            continue
        var override: Dictionary = raw_override
        var vehicle_id := str(override.get("id", ""))
        if vehicle_id.is_empty() or not _entries.has(vehicle_id):
            continue
        var merged: Dictionary = _entries[vehicle_id].duplicate(true)
        for key in override.keys():
            if str(key) == "id":
                continue
            merged[key] = override[key]
        merged["id"] = vehicle_id
        _entries[vehicle_id] = merged

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
