extends Node
class_name YardmanContentPackRuntime

signal pack_state_changed(pack_id: String, state: String, message: String)
signal pack_progress(pack_id: String, downloaded_bytes: int, total_bytes: int)
signal pack_installed(pack_id: String, version: int)

const CATALOG_PATH := "res://data/content_pack_catalog.json"
const CATALOG_OVERRIDE_PATH := "user://yardman/content-pack-catalog.json"
const STATE_PATH := "user://yardman/content-pack-state.json"
const PACK_ROOT := "user://yardman/packs/"
const DOWNLOAD_ROOT := "user://yardman/downloads/"
const MAX_ZIP_ENTRY_BYTES := 100663296

var _catalog: Dictionary = {}
var _packs: Dictionary = {}
var _state: Dictionary = {"format_version": 1, "packs": {}}
var _http: HTTPRequest
var _active_pack_id: String = ""
var _active_record: Dictionary = {}
var _active_chunk_index: int = -1
var _resume_offset: int = 0
var _retry_without_resume: bool = false
var _last_progress_emit_msec: int = 0

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(PACK_ROOT))
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DOWNLOAD_ROOT))
    _load_state()
    _load_catalog()
    _mount_installed_pcks()
    _http = HTTPRequest.new()
    _http.use_threads = true
    _http.accept_gzip = false
    _http.body_size_limit = -1
    _http.download_chunk_size = 262144
    _http.max_redirects = 8
    _http.timeout = 0.0
    _http.keep_partial_download = true
    _http.request_completed.connect(_on_request_completed)
    add_child(_http)
    set_process(true)

func _process(_delta: float) -> void:
    if _active_pack_id.is_empty() or _http == null:
        return
    var status: int = _http.get_http_client_status()
    if status == HTTPClient.STATUS_DISCONNECTED:
        return
    var now: int = Time.get_ticks_msec()
    if now - _last_progress_emit_msec < 200:
        return
    _last_progress_emit_msec = now
    var downloaded: int = _completed_chunk_bytes() + _resume_offset + maxi(_http.get_downloaded_bytes(), 0)
    pack_progress.emit(_active_pack_id, downloaded, _active_total_bytes())

func pack_ids() -> PackedStringArray:
    var ids := PackedStringArray()
    for raw_id: Variant in _packs.keys():
        ids.append(str(raw_id))
    ids.sort()
    return ids

func pack_record(pack_id: String) -> Dictionary:
    return (_packs.get(pack_id, {}) as Dictionary).duplicate(true)

func pack_status(pack_id: String) -> Dictionary:
    var record: Dictionary = _packs.get(pack_id, {}) as Dictionary
    if record.is_empty():
        return {"state": "unknown", "message": "Unknown content pack."}
    var pack_state: Dictionary = _pack_state(pack_id)
    var version: int = int(record.get("version", 0))
    var installed: bool = int(pack_state.get("installed_version", 0)) == version and bool(pack_state.get("complete", false))
    var chunks: Array = record.get("chunks", [])
    var available: bool = not chunks.is_empty() and _record_downloadable(record)
    return {
        "id": pack_id,
        "label": str(record.get("label", pack_id)),
        "version": version,
        "installed": installed,
        "available": available,
        "chunk_count": chunks.size(),
        "installed_chunks": (pack_state.get("installed_chunks", []) as Array).size(),
        "bytes": _record_total_bytes(record),
    }

func start_pack(pack_id: String) -> bool:
    if not _active_pack_id.is_empty():
        _emit_state(pack_id, "busy", "Another content pack is already downloading.")
        return false
    var record: Dictionary = _packs.get(pack_id, {}) as Dictionary
    if record.is_empty():
        _emit_state(pack_id, "error", "Unknown content pack.")
        return false
    if not _validate_pack_record(record):
        _emit_state(pack_id, "error", "Content-pack metadata is invalid.")
        return false
    var chunks: Array = record.get("chunks", [])
    if chunks.is_empty():
        _emit_state(pack_id, "unavailable", "This content pack has no published download shards yet.")
        return false
    if not _record_downloadable(record):
        _emit_state(pack_id, "unavailable", "This content pack is not published to a durable download endpoint yet.")
        return false
    var version: int = int(record.get("version", 0))
    var existing: Dictionary = _pack_state(pack_id)
    if int(existing.get("installed_version", 0)) == version and bool(existing.get("complete", false)):
        _emit_state(pack_id, "installed", "%s is already installed." % str(record.get("label", pack_id)))
        pack_installed.emit(pack_id, version)
        return true
    if int(existing.get("installed_version", 0)) != version:
        _state.packs[pack_id] = {
            "installed_version": version,
            "installed_chunks": [],
            "complete": false,
        }
        _save_state()
    _active_pack_id = pack_id
    _active_record = record
    _active_chunk_index = _next_missing_chunk_index(record, _pack_state(pack_id))
    if _active_chunk_index < 0:
        _complete_active_pack()
        return true
    _start_current_chunk(true)
    return true

func cancel_active_download() -> void:
    if _active_pack_id.is_empty():
        return
    var pack_id: String = _active_pack_id
    if _http != null:
        _http.cancel_request()
    _clear_active()
    _emit_state(pack_id, "paused", "Content download paused. Progress is kept for resume.")

func reload_catalog() -> bool:
    if not _active_pack_id.is_empty():
        return false
    _load_catalog()
    _mount_installed_pcks()
    return not _catalog.is_empty()

func _load_catalog() -> void:
    _catalog.clear()
    _packs.clear()
    var source: String = CATALOG_OVERRIDE_PATH if FileAccess.file_exists(CATALOG_OVERRIDE_PATH) else CATALOG_PATH
    if not FileAccess.file_exists(source):
        push_error("Yardman content-pack catalog missing: " + source)
        return
    var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(source))
    if not raw is Dictionary:
        push_error("Yardman content-pack catalog is invalid JSON")
        return
    var payload: Dictionary = raw as Dictionary
    if int(payload.get("format_version", 0)) != 1:
        push_error("Unsupported Yardman content-pack catalog version")
        return
    for raw_record: Variant in payload.get("packs", []):
        if not raw_record is Dictionary:
            continue
        var record: Dictionary = raw_record as Dictionary
        var pack_id: String = str(record.get("id", ""))
        if not _safe_id(pack_id) or _packs.has(pack_id):
            continue
        _packs[pack_id] = record
    _catalog = payload

func _load_state() -> void:
    if not FileAccess.file_exists(STATE_PATH):
        return
    var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(STATE_PATH))
    if raw is Dictionary and int((raw as Dictionary).get("format_version", 0)) == 1:
        _state = raw as Dictionary
    if not _state.get("packs", null) is Dictionary:
        _state["packs"] = {}

func _save_state() -> void:
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://yardman"))
    var file: FileAccess = FileAccess.open(STATE_PATH, FileAccess.WRITE)
    if file != null:
        file.store_string(JSON.stringify(_state))
        file.close()

func _pack_state(pack_id: String) -> Dictionary:
    var packs_state: Dictionary = _state.get("packs", {}) as Dictionary
    var raw: Variant = packs_state.get(pack_id, {})
    return raw as Dictionary if raw is Dictionary else {}

func _validate_pack_record(record: Dictionary) -> bool:
    var pack_id: String = str(record.get("id", ""))
    var install_root: String = str(record.get("install_root", ""))
    var version: int = int(record.get("version", 0))
    if not _safe_id(pack_id) or not _safe_id(install_root) or version <= 0:
        return false
    var chunks: Variant = record.get("chunks", null)
    if not chunks is Array:
        return false
    var seen: Dictionary = {}
    for raw_chunk: Variant in chunks as Array:
        if not raw_chunk is Dictionary:
            return false
        var chunk: Dictionary = raw_chunk as Dictionary
        var chunk_id: String = str(chunk.get("id", ""))
        var kind: String = str(chunk.get("kind", "pck"))
        if not _safe_id(chunk_id) or seen.has(chunk_id) or kind not in ["pck", "zip"]:
            return false
        seen[chunk_id] = true
        if chunk.has("url") and not str(chunk.get("url", "")).is_empty():
            if not str(chunk.get("url", "")).begins_with("https://"):
                return false
            if str(chunk.get("sha256", "")).length() != 64 or int(chunk.get("bytes", 0)) <= 0:
                return false
    return true

func _record_downloadable(record: Dictionary) -> bool:
    for raw_chunk: Variant in record.get("chunks", []):
        var chunk: Dictionary = raw_chunk as Dictionary
        if str(chunk.get("url", "")).is_empty() or str(chunk.get("sha256", "")).length() != 64 or int(chunk.get("bytes", 0)) <= 0:
            return false
    return true

func _record_total_bytes(record: Dictionary) -> int:
    var total: int = 0
    for raw_chunk: Variant in record.get("chunks", []):
        total += int((raw_chunk as Dictionary).get("bytes", 0))
    return total

func _next_missing_chunk_index(record: Dictionary, pack_state: Dictionary) -> int:
    var installed: Array = pack_state.get("installed_chunks", []) as Array
    var chunks: Array = record.get("chunks", []) as Array
    for i: int in range(chunks.size()):
        var chunk: Dictionary = chunks[i]
        if not installed.has(str(chunk.get("id", ""))):
            return i
    return -1

func _start_current_chunk(allow_resume: bool) -> void:
    if _active_pack_id.is_empty() or _active_chunk_index < 0:
        return
    var chunks: Array = _active_record.get("chunks", []) as Array
    if _active_chunk_index >= chunks.size():
        _complete_active_pack()
        return
    var chunk: Dictionary = chunks[_active_chunk_index]
    var temp_path: String = _chunk_temp_path(_active_record, chunk)
    _resume_offset = 0
    _retry_without_resume = not allow_resume
    var headers := PackedStringArray()
    if allow_resume and FileAccess.file_exists(temp_path):
        var existing: FileAccess = FileAccess.open(temp_path, FileAccess.READ)
        if existing != null:
            _resume_offset = int(existing.get_length())
        var expected_bytes: int = int(chunk.get("bytes", 0))
        if _resume_offset <= 0 or _resume_offset >= expected_bytes:
            DirAccess.remove_absolute(ProjectSettings.globalize_path(temp_path))
            _resume_offset = 0
        else:
            headers.append("Range: bytes=%d-" % _resume_offset)
    _http.download_file = temp_path
    _http.append_to_download_file = _resume_offset > 0
    _emit_state(_active_pack_id, "downloading", "Downloading %s · shard %d/%d" % [
        str(_active_record.get("label", _active_pack_id)), _active_chunk_index + 1, chunks.size()
    ])
    pack_progress.emit(_active_pack_id, _completed_chunk_bytes() + _resume_offset, _active_total_bytes())
    var err: Error = _http.request(str(chunk.get("url", "")), headers)
    if err != OK:
        _fail_active("Could not start content download (%s)." % error_string(err))

func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
    if _active_pack_id.is_empty():
        return
    var chunks: Array = _active_record.get("chunks", []) as Array
    if _active_chunk_index < 0 or _active_chunk_index >= chunks.size():
        _fail_active("Content download state became invalid.")
        return
    var chunk: Dictionary = chunks[_active_chunk_index]
    var temp_path: String = _chunk_temp_path(_active_record, chunk)
    if result != HTTPRequest.RESULT_SUCCESS:
        _fail_active("Content download failed. Tap retry to resume.")
        return
    if _resume_offset > 0 and response_code == 200 and not _retry_without_resume:
        DirAccess.remove_absolute(ProjectSettings.globalize_path(temp_path))
        _resume_offset = 0
        call_deferred("_start_current_chunk", false)
        return
    if response_code not in [200, 206]:
        _fail_active("Content server returned HTTP %d." % response_code)
        return
    if not FileAccess.file_exists(temp_path):
        _fail_active("Content download completed without a file.")
        return
    var handle: FileAccess = FileAccess.open(temp_path, FileAccess.READ)
    var actual_bytes: int = int(handle.get_length()) if handle != null else -1
    var expected_bytes: int = int(chunk.get("bytes", 0))
    if actual_bytes != expected_bytes:
        _fail_active("Content shard is incomplete (%d / %d bytes)." % [maxi(actual_bytes, 0), expected_bytes])
        return
    _emit_state(_active_pack_id, "verifying", "Verifying downloaded content…")
    var expected_sha: String = str(chunk.get("sha256", "")).to_lower()
    if FileAccess.get_sha256(temp_path).to_lower() != expected_sha:
        DirAccess.remove_absolute(ProjectSettings.globalize_path(temp_path))
        _fail_active("Content verification failed; the corrupted shard was discarded.")
        return
    _emit_state(_active_pack_id, "installing", "Installing content shard…")
    var installed_ok: bool = _install_chunk(_active_record, chunk, temp_path)
    if not installed_ok:
        _fail_active("Content shard could not be installed.")
        return
    _mark_chunk_installed(_active_pack_id, int(_active_record.get("version", 0)), str(chunk.get("id", "")))
    if str(chunk.get("kind", "pck")) == "zip":
        DirAccess.remove_absolute(ProjectSettings.globalize_path(temp_path))
    _active_chunk_index = _next_missing_chunk_index(_active_record, _pack_state(_active_pack_id))
    if _active_chunk_index < 0:
        _complete_active_pack()
    else:
        _start_current_chunk(true)

func _install_chunk(record: Dictionary, chunk: Dictionary, temp_path: String) -> bool:
    var kind: String = str(chunk.get("kind", "pck"))
    if kind == "pck":
        var final_path: String = _pck_final_path(record, chunk)
        DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(final_path.get_base_dir()))
        if FileAccess.file_exists(final_path):
            DirAccess.remove_absolute(ProjectSettings.globalize_path(final_path))
        if DirAccess.rename_absolute(ProjectSettings.globalize_path(temp_path), ProjectSettings.globalize_path(final_path)) != OK:
            return false
        if not ProjectSettings.load_resource_pack(final_path, false):
            return false
        return true
    return _extract_zip(record, temp_path)

func _extract_zip(record: Dictionary, archive_path: String) -> bool:
    var install_root: String = PACK_ROOT + str(record.get("install_root", "")) + "/"
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(install_root))
    var reader := ZIPReader.new()
    if reader.open(archive_path) != OK:
        return false
    for entry: String in reader.get_files():
        var clean: String = entry.replace("\\", "/")
        if clean.is_empty() or clean.begins_with("/") or clean.contains("../") or clean == ".." or clean.contains(":"):
            reader.close()
            return false
        if clean.ends_with("/"):
            DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(install_root + clean))
            continue
        var bytes: PackedByteArray = reader.read_file(entry)
        if bytes.size() > MAX_ZIP_ENTRY_BYTES:
            reader.close()
            return false
        var target: String = install_root + clean
        DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(target.get_base_dir()))
        var output: FileAccess = FileAccess.open(target, FileAccess.WRITE)
        if output == null:
            reader.close()
            return false
        output.store_buffer(bytes)
        output.close()
    reader.close()
    return true

func _mark_chunk_installed(pack_id: String, version: int, chunk_id: String) -> void:
    var packs_state: Dictionary = _state.get("packs", {}) as Dictionary
    var entry: Dictionary = packs_state.get(pack_id, {}) as Dictionary
    if int(entry.get("installed_version", 0)) != version:
        entry = {"installed_version": version, "installed_chunks": [], "complete": false}
    var installed: Array = entry.get("installed_chunks", []) as Array
    if not installed.has(chunk_id):
        installed.append(chunk_id)
    entry["installed_chunks"] = installed
    packs_state[pack_id] = entry
    _state["packs"] = packs_state
    _save_state()

func _complete_active_pack() -> void:
    var pack_id: String = _active_pack_id
    var version: int = int(_active_record.get("version", 0))
    var label: String = str(_active_record.get("label", pack_id))
    var packs_state: Dictionary = _state.get("packs", {}) as Dictionary
    var entry: Dictionary = packs_state.get(pack_id, {}) as Dictionary
    entry["installed_version"] = version
    entry["complete"] = true
    entry["installed_at_unix"] = int(Time.get_unix_time_from_system())
    packs_state[pack_id] = entry
    _state["packs"] = packs_state
    _save_state()
    _clear_active()
    _emit_state(pack_id, "installed", "%s installed." % label)
    pack_installed.emit(pack_id, version)

func _fail_active(message: String) -> void:
    var pack_id: String = _active_pack_id
    _clear_active()
    _emit_state(pack_id, "error", message)

func _clear_active() -> void:
    _active_pack_id = ""
    _active_record.clear()
    _active_chunk_index = -1
    _resume_offset = 0
    _retry_without_resume = false

func _mount_installed_pcks() -> void:
    for raw_id: Variant in _packs.keys():
        var pack_id: String = str(raw_id)
        var record: Dictionary = _packs[pack_id] as Dictionary
        var state: Dictionary = _pack_state(pack_id)
        if int(state.get("installed_version", 0)) != int(record.get("version", 0)):
            continue
        var installed: Array = state.get("installed_chunks", []) as Array
        for raw_chunk: Variant in record.get("chunks", []):
            var chunk: Dictionary = raw_chunk as Dictionary
            var chunk_id: String = str(chunk.get("id", ""))
            if str(chunk.get("kind", "pck")) != "pck" or not installed.has(chunk_id):
                continue
            var path: String = _pck_final_path(record, chunk)
            if FileAccess.file_exists(path):
                ProjectSettings.load_resource_pack(path, false)

func _chunk_temp_path(record: Dictionary, chunk: Dictionary) -> String:
    return "%s%s-v%d-%s.part" % [DOWNLOAD_ROOT, str(record.get("id", "pack")),
        int(record.get("version", 0)), str(chunk.get("id", "chunk"))]

func _pck_final_path(record: Dictionary, chunk: Dictionary) -> String:
    return "%s%s/v%d/%s.pck" % [PACK_ROOT, str(record.get("install_root", "pack")),
        int(record.get("version", 0)), str(chunk.get("id", "chunk"))]

func _completed_chunk_bytes() -> int:
    if _active_pack_id.is_empty():
        return 0
    var installed: Array = _pack_state(_active_pack_id).get("installed_chunks", []) as Array
    var total: int = 0
    for raw_chunk: Variant in _active_record.get("chunks", []):
        var chunk: Dictionary = raw_chunk as Dictionary
        if installed.has(str(chunk.get("id", ""))):
            total += int(chunk.get("bytes", 0))
    return total

func _active_total_bytes() -> int:
    return _record_total_bytes(_active_record) if not _active_record.is_empty() else 0

func _safe_id(value: String) -> bool:
    if value.is_empty() or value.length() > 64 or value.begins_with("."):
        return false
    for i: int in range(value.length()):
        var code: int = value.unicode_at(i)
        var ok: bool = (code >= 48 and code <= 57) or (code >= 65 and code <= 90) or (code >= 97 and code <= 122) or code in [45, 95]
        if not ok:
            return false
    return true

func _emit_state(pack_id: String, state_name: String, message: String) -> void:
    pack_state_changed.emit(pack_id, state_name, message)
