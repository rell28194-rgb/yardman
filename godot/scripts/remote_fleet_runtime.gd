extends Node
class_name YardmanRemoteFleetRuntime

signal state_changed(state: String, message: String)
signal progress_changed(downloaded_bytes: int, total_bytes: int)
signal installed

const PACK_URL := "https://www.dropbox.com/scl/fi/jv54iuqhthvejvuy6zezc/Yardman-Owner-Recovery-Private-Fleet-64-2026-10-19.zip?rlkey=80kgw28rol81hnia2xbikuspe&dl=1"
const PACK_SHA256 := "6b1130bcd9a6ab554c3134710b348050d1a03e40c6c3f16136fefbeda5c5e75b"
const PACK_BYTES := 159594070
const ROOT := "user://yardman/fleet64/"
const ARCHIVE_PATH := "user://yardman/fleet64-download.zip.part"
const MARKER_PATH := "user://yardman/fleet64-installed.json"
const MANIFEST_PATH := ROOT + "manifest.json"

var _http: HTTPRequest
var _state := "idle"
var _message := "Vehicle pack not installed."
var _resume_offset := 0
var _last_progress_emit_msec := 0

func _ready() -> void:
    process_mode = Node.PROCESS_MODE_ALWAYS
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://yardman"))
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
    if is_installed():
        _set_state("installed", "64-vehicle pack installed.")
    else:
        _set_state("idle", "Vehicle pack ready to download over Wi-Fi.")

func _process(_delta: float) -> void:
    if _state != "downloading" or _http == null:
        return
    var now := Time.get_ticks_msec()
    if now - _last_progress_emit_msec < 200:
        return
    _last_progress_emit_msec = now
    var downloaded := _resume_offset + max(_http.get_downloaded_bytes(), 0)
    progress_changed.emit(min(downloaded, PACK_BYTES), PACK_BYTES)

func get_state() -> String:
    return _state

func get_message() -> String:
    return _message

func is_installed() -> bool:
    if not FileAccess.file_exists(MARKER_PATH) or not FileAccess.file_exists(MANIFEST_PATH):
        return false
    var marker = JSON.parse_string(FileAccess.get_file_as_string(MARKER_PATH))
    if not marker is Dictionary:
        return false
    return str(marker.get("pack_sha256", "")).to_lower() == PACK_SHA256 and int(marker.get("pack_bytes", 0)) == PACK_BYTES

func start_download() -> bool:
    if is_installed():
        _set_state("installed", "64-vehicle pack already installed.")
        installed.emit()
        return true
    if _state in ["downloading", "verifying", "installing"]:
        return false

    _resume_offset = 0
    var headers := PackedStringArray()
    if FileAccess.file_exists(ARCHIVE_PATH):
        var existing := FileAccess.open(ARCHIVE_PATH, FileAccess.READ)
        if existing != null:
            _resume_offset = int(existing.get_length())
        if _resume_offset <= 0 or _resume_offset >= PACK_BYTES:
            DirAccess.remove_absolute(ProjectSettings.globalize_path(ARCHIVE_PATH))
            _resume_offset = 0
        else:
            headers.append("Range: bytes=%d-" % _resume_offset)

    _http.download_file = ARCHIVE_PATH
    _http.append_to_download_file = _resume_offset > 0
    _set_state("downloading", "Downloading vehicle pack… keep the game open and stay on Wi-Fi.")
    progress_changed.emit(_resume_offset, PACK_BYTES)
    var err := _http.request(PACK_URL, headers)
    if err != OK:
        _set_state("error", "Could not start vehicle download (%s)." % error_string(err))
        return false
    return true

func cancel_download() -> void:
    if _state == "downloading" and _http != null:
        _http.cancel_request()
        _set_state("idle", "Vehicle download paused. Tap download to resume.")

func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
    if result != HTTPRequest.RESULT_SUCCESS or response_code not in [200, 206]:
        _set_state("error", "Vehicle download failed. Tap download to resume.")
        return
    if not FileAccess.file_exists(ARCHIVE_PATH):
        _set_state("error", "Vehicle download finished without a file.")
        return

    var handle := FileAccess.open(ARCHIVE_PATH, FileAccess.READ)
    var size := int(handle.get_length()) if handle != null else -1
    if size != PACK_BYTES:
        _set_state("error", "Vehicle download is incomplete (%d / %d bytes). Tap download to resume." % [max(size, 0), PACK_BYTES])
        return

    _set_state("verifying", "Verifying vehicle pack…")
    var digest := FileAccess.get_sha256(ARCHIVE_PATH).to_lower()
    if digest != PACK_SHA256:
        DirAccess.remove_absolute(ProjectSettings.globalize_path(ARCHIVE_PATH))
        _set_state("error", "Vehicle pack verification failed. The bad download was discarded.")
        return

    _set_state("installing", "Installing vehicles…")
    if not _extract_archive():
        _set_state("error", "Vehicle pack could not be installed.")
        return
    if not FileAccess.file_exists(MANIFEST_PATH):
        _set_state("error", "Vehicle pack manifest is missing after install.")
        return

    var marker_file := FileAccess.open(MARKER_PATH, FileAccess.WRITE)
    if marker_file == null:
        _set_state("error", "Could not save vehicle installation state.")
        return
    marker_file.store_string(JSON.stringify({
        "pack_sha256": PACK_SHA256,
        "pack_bytes": PACK_BYTES,
        "installed_at_unix": int(Time.get_unix_time_from_system())
    }))
    marker_file.close()
    DirAccess.remove_absolute(ProjectSettings.globalize_path(ARCHIVE_PATH))
    _set_state("installed", "64-vehicle pack installed.")
    progress_changed.emit(PACK_BYTES, PACK_BYTES)
    installed.emit()

func _extract_archive() -> bool:
    var reader := ZIPReader.new()
    if reader.open(ARCHIVE_PATH) != OK:
        return false
    var root_abs := ProjectSettings.globalize_path(ROOT)
    DirAccess.make_dir_recursive_absolute(root_abs)
    for entry in reader.get_files():
        var clean := entry.replace("\\", "/")
        if clean.is_empty() or clean.begins_with("/") or clean.contains("../") or clean == "..":
            reader.close()
            return false
        if clean.ends_with("/"):
            DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT + clean))
            continue
        var target := ROOT + clean
        DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(target.get_base_dir()))
        var output := FileAccess.open(target, FileAccess.WRITE)
        if output == null:
            reader.close()
            return false
        var bytes := reader.read_file(entry)
        output.store_buffer(bytes)
        output.close()
    reader.close()
    return true

func _set_state(value: String, message: String) -> void:
    _state = value
    _message = message
    state_changed.emit(_state, _message)
