extends RefCounted
class_name YardmanSaveGame

static func valid(snapshot: Dictionary) -> bool:
    if int(snapshot.get("schema", 0)) != 1 or str(snapshot.get("crs", "")) != "EPSG:3448":
        return false
    for actor in ["car", "player"]:
        var state = snapshot.get(actor)
        if not state is Dictionary:
            return false
        for field in ["easting", "northing", "elevation"]:
            if not state.has(field) or not (state[field] is float or state[field] is int) or not is_finite(float(state[field])):
                return false
    return true

static func save_file(path: String, snapshot: Dictionary) -> Error:
    if not valid(snapshot):
        return ERR_INVALID_DATA
    var encoded := JSON.stringify(snapshot, "", true, true)
    # Hash the exact stored UTF-8 text. JSON.parse_string converts JSON integers
    # to floats, so re-serializing a parsed dictionary changes e.g. schema 1 to
    # 1.0 and would reject every otherwise valid save.
    var wrapper := {"payload_json": encoded, "sha256": encoded.sha256_text()}
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
    if _read_valid(temporary).is_empty():
        return ERR_FILE_CORRUPT
    if FileAccess.file_exists(path):
        if FileAccess.file_exists(path + ".bak"):
            DirAccess.remove_absolute(path + ".bak")
        error = DirAccess.rename_absolute(path, path + ".bak")
        if error != OK:
            return error
    error = DirAccess.rename_absolute(temporary, path)
    if error != OK and FileAccess.file_exists(path + ".bak"):
        DirAccess.rename_absolute(path + ".bak", path)
    return error

static func load_file(path: String) -> Dictionary:
    var snapshot := _read_valid(path)
    return _read_valid(path + ".bak") if snapshot.is_empty() else snapshot

static func _read_valid(path: String) -> Dictionary:
    if not FileAccess.file_exists(path):
        return {}
    var wrapper = JSON.parse_string(FileAccess.get_file_as_string(path))
    if not wrapper is Dictionary or not wrapper.get("payload_json") is String:
        return {}
    var encoded: String = wrapper.payload_json
    if encoded.sha256_text() != str(wrapper.get("sha256", "")):
        return {}
    var payload = JSON.parse_string(encoded)
    if not payload is Dictionary or not valid(payload):
        return {}
    return payload
