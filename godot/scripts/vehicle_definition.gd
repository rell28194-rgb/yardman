extends RefCounted
class_name YardmanVehicleDefinition

const ROOT := "res://data/vehicles"
const INDEX_PATH := "res://data/vehicles/index.json"
const FORMAT_VERSION := 1
const RUNTIME_READY_STATUSES := ["GAME-READY", "HIGH-FIDELITY", "ACCEPTED"]

static var _cache: Dictionary = {}
static var _registry_cache: Array[String] = []
static var _registry_loaded := false

static func definition_path(vehicle_id: String) -> String:
    if not _safe_id(vehicle_id):
        return ""
    return "%s/%s/vehicle.json" % [ROOT, vehicle_id]

static func registry_ids(runtime_ready_only := false) -> Array[String]:
    _ensure_registry()
    if not runtime_ready_only:
        return _registry_cache.duplicate()
    var ready: Array[String] = []
    for vehicle_id in _registry_cache:
        if runtime_ready(vehicle_id):
            ready.append(vehicle_id)
    return ready

static func hierarchy_path(vehicle_id: String) -> String:
    var definition: Dictionary = load_definition(vehicle_id)
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
    var payload: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
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
    var definition: Dictionary = load_definition(vehicle_id)
    return str(definition.get("status", "LEGACY")) if not definition.is_empty() else "LEGACY"

static func runtime_ready(vehicle_id: String) -> bool:
    var definition: Dictionary = load_definition(vehicle_id)
    if definition.is_empty():
        return false
    if not RUNTIME_READY_STATUSES.has(str(definition.get("status", ""))):
        return false
    var runtime_value: Variant = definition.get("runtime", {})
    return runtime_value is Dictionary and bool((runtime_value as Dictionary).get("ready", false))

static func primary_scene(vehicle_id: String) -> String:
    var definition: Dictionary = load_definition(vehicle_id)
    if definition.is_empty():
        return ""
    var visual_value: Variant = definition.get("visual", {})
    if not visual_value is Dictionary:
        return ""
    return str((visual_value as Dictionary).get("primary_scene", ""))

static func inspection_scene(vehicle_id: String) -> String:
    var definition: Dictionary = load_definition(vehicle_id)
    if definition.is_empty():
        return ""
    var visual_value: Variant = definition.get("visual", {})
    if not visual_value is Dictionary:
        return ""
    return str((visual_value as Dictionary).get("inspection_scene", ""))

static func dynamics(vehicle_id: String) -> Dictionary:
    var definition: Dictionary = load_definition(vehicle_id)
    if definition.is_empty():
        return {}
    var value: Variant = definition.get("dynamics", {})
    return (value as Dictionary).duplicate(true) if value is Dictionary else {}

static func customization(vehicle_id: String) -> Dictionary:
    var definition: Dictionary = load_definition(vehicle_id)
    if definition.is_empty():
        return {}
    var value: Variant = definition.get("customization", {})
    return (value as Dictionary).duplicate(true) if value is Dictionary else {}

static func upgrades(vehicle_id: String) -> Dictionary:
    var definition: Dictionary = load_definition(vehicle_id)
    if definition.is_empty():
        return {}
    var value: Variant = definition.get("upgrades", {})
    return (value as Dictionary).duplicate(true) if value is Dictionary else {}

static func source_summary(vehicle_id: String) -> Dictionary:
    var definition: Dictionary = load_definition(vehicle_id)
    if definition.is_empty():
        return {}
    var value: Variant = definition.get("source", {})
    return (value as Dictionary).duplicate(true) if value is Dictionary else {}

static func clear_cache() -> void:
    _cache.clear()
    _registry_cache.clear()
    _registry_loaded = false

static func _ensure_registry() -> void:
    if _registry_loaded:
        return
    _registry_loaded = true
    _registry_cache.clear()
    if not FileAccess.file_exists(INDEX_PATH):
        return
    var payload: Variant = JSON.parse_string(FileAccess.get_file_as_string(INDEX_PATH))
    if not payload is Dictionary or int((payload as Dictionary).get("format_version", 0)) != FORMAT_VERSION:
        push_warning("Yardman vehicle registry is invalid: %s" % INDEX_PATH)
        return
    var raw_ids: Variant = (payload as Dictionary).get("vehicle_ids", [])
    if not raw_ids is Array:
        push_warning("Yardman vehicle registry has no vehicle_ids array: %s" % INDEX_PATH)
        return
    for raw_id: Variant in raw_ids:
        var vehicle_id: String = str(raw_id)
        if not _safe_id(vehicle_id) or _registry_cache.has(vehicle_id):
            continue
        # An index entry without a valid definition is not allowed to enter the runtime registry.
        if load_definition(vehicle_id).is_empty():
            push_warning("Yardman vehicle registry points at an invalid definition: %s" % vehicle_id)
            continue
        _registry_cache.append(vehicle_id)
    _registry_cache.sort()

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
    var visual_value: Variant = definition.get("visual", {})
    if visual_value is Dictionary:
        for key in ["primary_scene", "inspection_scene"]:
            var value: String = str((visual_value as Dictionary).get(key, ""))
            if value.contains("..") or value.contains("\\"):
                return false
    var dynamics_value: Variant = definition.get("dynamics", {})
    if dynamics_value is Dictionary:
        var top_speed: float = float((dynamics_value as Dictionary).get("top_speed_mps", 0.0))
        if top_speed < 0.0 or top_speed > 180.0:
            return false
    return true
