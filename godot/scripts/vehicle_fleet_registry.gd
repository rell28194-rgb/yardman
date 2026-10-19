extends RefCounted
class_name YardmanVehicleFleetRegistry

const References = preload("res://scripts/reference_assets.gd")
const BLOCKED_IDS := ["toyota_mark_x", "port_royal_992"]

static var _entries: Dictionary = {}
static var _ids: Array[String] = []
static var _loaded := false

static func _manufacturer_for(vehicle_id: String) -> String:
    if vehicle_id.begins_with("carx_ae86") or vehicle_id.begins_with("toyota_"):
        return "Toyota"
    if vehicle_id.begins_with("audi_"):
        return "Audi"
    if vehicle_id.begins_with("bmw_"):
        return "BMW"
    if vehicle_id.begins_with("chevrolet_"):
        return "Chevrolet"
    if vehicle_id.begins_with("dodge_"):
        return "Dodge"
    if vehicle_id.begins_with("honda_"):
        return "Honda"
    if vehicle_id.begins_with("lexus_"):
        return "Lexus"
    if vehicle_id.begins_with("mazda_"):
        return "Mazda"
    if vehicle_id.begins_with("mercedes_"):
        return "Mercedes-Benz"
    if vehicle_id.begins_with("mitsubishi_"):
        return "Mitsubishi"
    if vehicle_id.begins_with("mustang_"):
        return "Ford"
    if vehicle_id.begins_with("nissan_"):
        return "Nissan"
    if vehicle_id.begins_with("subaru_"):
        return "Subaru"
    return "Yardman"

static func _display_name(vehicle_id: String, manufacturer: String) -> String:
    var label := vehicle_id.replace("carx_", "").replace("_source", "").replace("_", " ").capitalize()
    if manufacturer == "BMW":
        label = label.replace("Bmw ", "BMW ")
    elif manufacturer == "Mercedes-Benz":
        label = label.replace("Mercedes ", "")
    elif manufacturer == "Ford" and label.begins_with("Mustang"):
        return "Ford " + label
    if manufacturer != "Yardman" and not label.begins_with(manufacturer):
        return manufacturer + " " + label
    return label

static func _ensure_loaded() -> void:
    if _loaded:
        return
    _loaded = true
    var payload := References.manifest()
    if payload.is_empty():
        return
    var seen: Dictionary = {}
    for raw_record in payload.get("files", []):
        if not raw_record is Dictionary:
            continue
        var filename := str(raw_record.get("path", ""))
        if not filename.begins_with("fleet_") or filename.get_extension().to_lower() != "glb":
            continue
        var vehicle_id := filename.get_basename().trim_prefix("fleet_")
        if vehicle_id.is_empty() or BLOCKED_IDS.has(vehicle_id) or seen.has(vehicle_id):
            continue
        seen[vehicle_id] = true
        var manufacturer := _manufacturer_for(vehicle_id)
        _entries[vehicle_id] = {
            "id": vehicle_id,
            "manufacturer": manufacturer,
            "display_name": _display_name(vehicle_id, manufacturer),
            "hero_scene": filename,
            "private_media": true,
        }
        _ids.append(vehicle_id)
    _ids.sort()

static func has(vehicle_id: String) -> bool:
    _ensure_loaded()
    return _entries.has(vehicle_id)

static func entry(vehicle_id: String) -> Dictionary:
    _ensure_loaded()
    return _entries[vehicle_id].duplicate(true) if _entries.has(vehicle_id) else {}

static func ids() -> Array[String]:
    _ensure_loaded()
    return _ids.duplicate()

static func count() -> int:
    _ensure_loaded()
    return _entries.size()
