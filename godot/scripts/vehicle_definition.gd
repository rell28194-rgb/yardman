extends RefCounted
class_name YardmanVehicleDefinition

const ROOT := "res://data/vehicles"
const FORMAT_VERSION := 1
const RUNTIME_READY_STATUSES := ["GAME-READY", "HIGH-FIDELITY", "ACCEPTED"]

static var _cache: Dictionary = {}

static func definition_path(vehicle_id: String) -> String:
    if not _safe_id(vehicle_id):
        return ""
    return "%s/%s/vehicle.json" % [ROOT, vehicle_id]

static func hierarchy_path(vehicle_id: String) -> String:
    var definition := load_definition(vehicle_id)
    if definition.is_empty():
        return ""
    return str(definition.get("hierarchy_descriptor", ""))

static func has_definition(vehicle_id: String) -> bool:
    return not load_definition(vehicle_id).is_empty()

static func load_definition(vehicle_id: String) -> Dictionary:
    if not _safe_id(vehicle_id):
        return {}
    if _cache.has(vehicle_id):
        return (_cache[vehicle_id] as Dictionary).duplicate(true)
    var path := definition_path(vehicle_id)
    if path.is_empty() or not FileAccess.file_exists(path):
        _cache[vehicle_id] = {}
        return {}
    var payload = JSON.parse_string(FileAccess.get_file_as_string(path))
    if not payload is Dictionary:
        push_warning("Yardman vehicle definition is not a JSON object: %s" % path)
        _cache[vehicle_id] = {}
        return {}
    var definition: Dictionary = payload
    if int(definition.get("format_version", 0)) != FORMAT_VERSION:
        push_warning("Yardman vehicle definition has unsupported format: %s" % path)
        _cache[vehicle_id] = {}
        return {}
    if str(definition.get("vehicle_id", "")) != vehicle_id:
        push_warning("Yardman vehicle definition id mismatch: %s" % path)
        _cache[vehicle_id] = {}
        return {}
    if not _definition_is_sane(definition):
        push_warning("Yardman vehicle definition failed runtime sanity checks: %s" % path)
        _cache[vehicle_id] = {}
        return {}
    _cache[vehicle_id] = definition.duplicate(true)
    return definition.duplicate(true)

static func status(vehicle_id: String) -> String:
    var definition := load_definition(vehicle_id)
    return str(definition.get("status", "LEGACY")) if not definition.is_empty() else "LEGACY"

static func runtime_ready(vehicle_id: String) -> bool:
    var definition := load_definition(vehicle_id)
    if definition.is_empty():
        return false
    if not RUNTIME_READY_STATUSES.has(str(definition.get("status", ""))):
        return false
    var runtime := definition.get("runtime", {})
    return runtime is Dictionary and bool((runtime as Dictionary).get("ready", false))

static func primary_scene(vehicle_id: String) -> String:
    var definition := load_definition(vehicle_id)
    if definition.is_empty():
        return ""
    var visual := definition.get("visual", {})
    if not visual is Dictionary:
        return ""
    return str((visual as Dictionary).get("primary_scene", ""))

static func inspection_scene(vehicle_id: String) -> String:
    var definition := load_definition(vehicle_id)
    if definition.is_empty():
        return ""
    var visual := definition.get("visual", {})
    if not visual is Dictionary:
        return ""
    return str((visual as Dictionary).get("inspection_scene", ""))

static func dynamics(vehicle_id: String) -> Dictionary:
    var definition := load_definition(vehicle_id)
    if definition.is_empty():
        return {}
    var value := definition.get("dynamics", {})
    return (value as Dictionary).duplicate(true) if value is Dictionary else {}

static func customization(vehicle_id: String) -> Dictionary:
    var definition := load_definition(vehicle_id)
    if definition.is_empty():
        return {}
    var value := definition.get("customization", {})
    return (value as Dictionary).duplicate(true) if value is Dictionary else {}

static func upgrades(vehicle_id: String) -> Dictionary:
    var definition := load_definition(vehicle_id)
    if definition.is_empty():
        return {}
    var value := definition.get("upgrades", {})
    return (value as Dictionary).duplicate(true) if value is Dictionary else {}

static func source_summary(vehicle_id: String) -> Dictionary:
    var definition := load_definition(vehicle_id)
    if definition.is_empty():
        return {}
    var value := definition.get("source", {})
    return (value as Dictionary).duplicate(true) if value is Dictionary else {}

static func clear_cache() -> void:
    _cache.clear()

static func _safe_id(vehicle_id: String) -> bool:
    if vehicle_id.is_empty() or vehicle_id.length() > 96:
        return false
    for ch in vehicle_id:
        if not (ch.is_valid_identifier() or ch == "-" or ch == "."):
            # is_valid_identifier() on a single digit is false, so explicitly allow digits.
            if ch < "0" or ch > "9":
                return false
    return not vehicle_id.contains("/") and not vehicle_id.contains("\\") and not vehicle_id.contains("..")

static func _definition_is_sane(definition: Dictionary) -> bool:
    if not definition.get("status", "") is String:
        return false
    var visual := definition.get("visual", {})
    if visual is Dictionary:
        for key in ["primary_scene", "inspection_scene"]:
            var value := str((visual as Dictionary).get(key, ""))
            if value.contains("..") or value.contains("\\"):
                return false
    var dynamics_value := definition.get("dynamics", {})
    if dynamics_value is Dictionary:
        var top_speed := float((dynamics_value as Dictionary).get("top_speed_mps", 0.0))
        if top_speed < 0.0 or top_speed > 180.0:
            return false
    return true
