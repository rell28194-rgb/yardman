extends Node
class_name YardmanJobPersistenceRuntime

const SAVE_PATH := "user://yardman/jobs.json"
const SAVE_INTERVAL := 15.0
const VehicleCatalog = preload("res://scripts/vehicle_catalog.gd")
var _clock := 0.0

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    call_deferred("_load_state")

func _process(delta: float) -> void:
    _clock += delta
    if _clock >= SAVE_INTERVAL:
        _clock = 0.0
        _save_state()

func _notification(what: int) -> void:
    if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_APPLICATION_PAUSED:
        _save_state()

func _load_state() -> void:
    var runtime := get_node_or_null("/root/JobRuntime")
    if runtime == null:
        return
    var state := read_state(SAVE_PATH)
    if not state.is_empty():
        runtime.call("restore_snapshot", state)

func _save_state() -> void:
    var runtime := get_node_or_null("/root/JobRuntime")
    if runtime == null:
        return
    var state_value = runtime.call("save_snapshot")
    if not state_value is Dictionary or not valid_state(state_value):
        return
    write_state(SAVE_PATH, state_value)

static func valid_state(state: Dictionary) -> bool:
    if state.has("garage_owned_ids"):
        var ownership = state["garage_owned_ids"]
        if not ownership is Array or not ownership.has("toyota_crown"):
            return false
        var seen: Dictionary = {}
        for vehicle_id in ownership:
            if not vehicle_id is String or not VehicleCatalog.production_ids().has(vehicle_id) or seen.has(vehicle_id):
                return false
            seen[vehicle_id] = true
    var wallet = state.get("wallet_jmd", null)
    var sequence = state.get("offer_sequence", null)
    if not (wallet is int or wallet is float) or not is_finite(float(wallet)) or int(wallet) < 0:
        return false
    if not (sequence is int or sequence is float) or not is_finite(float(sequence)) or int(sequence) < 0:
        return false
    var job = state.get("active_job", {})
    if not job is Dictionary:
        return false
    return job.is_empty() or YardmanJobRuntime._valid_persisted_job(job)

static func wrap_state(state: Dictionary) -> Dictionary:
    if not valid_state(state):
        return {}
    var encoded := JSON.stringify(state, "", true, true)
    return {"payload_json": encoded, "sha256": encoded.sha256_text()}

static func unwrap_state(wrapper: Variant) -> Dictionary:
    if not wrapper is Dictionary:
        return {}
    var encoded = wrapper.get("payload_json", null)
    if not encoded is String or encoded.sha256_text() != str(wrapper.get("sha256", "")):
        return {}
    var state = JSON.parse_string(encoded)
    if not state is Dictionary or not valid_state(state):
        return {}
    return state

static func write_state(path: String, state: Dictionary) -> Error:
    var wrapper := wrap_state(state)
    if wrapper.is_empty():
        return ERR_INVALID_DATA
    var directory := ProjectSettings.globalize_path(path.get_base_dir())
    var error := DirAccess.make_dir_recursive_absolute(directory)
    if error != OK:
        return error
    var temporary := path + ".tmp"
    var file := FileAccess.open(temporary, FileAccess.WRITE)
    if file == null:
        return FileAccess.get_open_error()
    file.store_string(JSON.stringify(wrapper, "", true, true))
    file.flush()
    file.close()
    if read_state(temporary).is_empty():
        return ERR_FILE_CORRUPT
    return _commit_staged(temporary, path)

static func _commit_staged(temporary: String, path: String) -> Error:
    var error := OK
    if FileAccess.file_exists(path):
        if not _read_valid(path).is_empty():
            if FileAccess.file_exists(path + ".bak"):
                error = DirAccess.remove_absolute(path + ".bak")
                if error != OK:
                    return error
            error = DirAccess.rename_absolute(path, path + ".bak")
        else:
            # A recovered backup is the last good checkpoint. Never replace it
            # with the corrupt primary while installing the next valid save.
            error = DirAccess.remove_absolute(path)
        if error != OK:
            return error
    error = DirAccess.rename_absolute(temporary, path)
    if error != OK and not _read_valid(path + ".bak").is_empty():
        DirAccess.rename_absolute(path + ".bak", path)
    return error

static func read_state(path: String) -> Dictionary:
    var state := _read_valid(path)
    return _read_valid(path + ".bak") if state.is_empty() else state

static func _read_valid(path: String) -> Dictionary:
    if not FileAccess.file_exists(path):
        return {}
    var json := JSON.new()
    if json.parse(FileAccess.get_file_as_string(path)) != OK:
        return {}
    return unwrap_state(json.data)
